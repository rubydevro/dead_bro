#!/usr/bin/env ruby
# frozen_string_literal: true

require "rbconfig"

module DeadBro
  module Collectors
    # System collector provides best-effort CPU and memory statistics
    # using cgroups when available and falling back to /proc on Linux.
    #
    # CPU percentages are normalised to 0..100 across all cores. The first
    # run may not contain a CPU percentage because there is no previous
    # sample to diff against.
    module System
      module_function

      CPU_SAMPLE_KEY = "cpu".freeze
      MEMINFO_PATH   = "/proc/meminfo".freeze

      def collect
        return { enabled: false } unless system_enabled?

        {
          cpu_pct: cpu_percentage,
          mem_used_bytes: mem_used_bytes,
          mem_total_bytes: mem_total_bytes,
          mem_available_bytes: mem_available_bytes,
          disk: Filesystem.collect
        }
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      def system_enabled?
        DeadBro.configuration.respond_to?(:enable_system_stats) &&
          DeadBro.configuration.enable_system_stats
      rescue StandardError
        false
      end

      def linux?
        host_os = RbConfig::CONFIG["host_os"].to_s.downcase
        host_os.include?("linux")
      rescue StandardError
        false
      end

      def macos?
        host_os = RbConfig::CONFIG["host_os"].to_s.downcase
        host_os.include?("darwin")
      rescue StandardError
        false
      end

      # CPU percentage normalised to 0..100
      def cpu_percentage
        if linux?
          cpu_percentage_linux
        elsif macos?
          cpu_percentage_macos
        else
          nil
        end
      end

      def cpu_percentage_linux
        return nil unless File.readable?("/proc/stat")

        now = current_time
        current = read_proc_stat
        prev = SampleStore.load(CPU_SAMPLE_KEY)
        SampleStore.save(CPU_SAMPLE_KEY, { "timestamp" => now, "stat" => current })

        return nil unless prev && prev["stat"].is_a?(Hash) && prev["timestamp"]

        cpu_pct_from_samples(prev["stat"], current)
      rescue StandardError
        nil
      end

      def cpu_percentage_macos
        output = `top -l 1 -n 0 | grep "CPU usage"`
        # Example: CPU usage: 9.38% user, 10.93% sys, 79.68% idle 
        if output =~ /([\d\.]+)% idle/
          idle = $1.to_f
          (100.0 - idle).round(2)
        else
          nil
        end
      rescue StandardError
        nil
      end

      def current_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.now.to_f
      end

      # Parse the first "cpu" line from /proc/stat
      def read_proc_stat
        File.foreach("/proc/stat") do |line|
          next unless line.start_with?("cpu ")

          fields = line.split
          # cpu  user nice system idle iowait irq softirq steal guest guest_nice
          values = fields[1..-1].map { |v| v.to_i }
          total = values.sum
          idle = values[3] + values[4] # idle + iowait
          return { "total" => total, "idle" => idle }
        end
        {}
      rescue StandardError
        {}
      end

      # Computes a CPU percentage from two /proc/stat samples.
      # This is intentionally public so it can be unit tested.
      def cpu_pct_from_samples(prev, current)
        prev_total = prev["total"].to_f
        prev_idle  = prev["idle"].to_f
        cur_total  = current["total"].to_f
        cur_idle   = current["idle"].to_f

        total_delta = cur_total - prev_total
        idle_delta  = cur_idle - prev_idle
        return nil if total_delta <= 0

        usage = (total_delta - idle_delta) / total_delta.to_f
        pct = (usage * 100.0)
        return nil unless pct.finite?

        pct.round(2)
      rescue StandardError
        nil
      end

      def meminfo
        return {} unless linux? && File.readable?(MEMINFO_PATH)

        info = {}
        File.foreach(MEMINFO_PATH) do |line|
          key, value, unit = line.split
          next unless key && value

          key = key.sub(":", "")
          info[key] = Integer(value) rescue nil
        end
        info
      rescue StandardError
        {}
      end

      def mem_total_bytes
        if linux?
          info = meminfo
          total_kb = info["MemTotal"]
          return nil unless total_kb
          total_kb * 1024
        elsif macos?
          `sysctl -n hw.memsize`.to_i
        else
          nil
        end
      rescue StandardError
        nil
      end

      def mem_available_bytes
        if linux?
          info = meminfo
          avail_kb = info["MemAvailable"] || info["MemFree"]
          return nil unless avail_kb
          avail_kb * 1024
        elsif macos?
          # vm_stat output:
          # Pages free:                               3632.
          # Pages active:                           138466.
          # Pages inactive:                         134812.
          # ...
          output = `vm_stat`
          pages_free = output[/Pages free:\s+(\d+)/, 1].to_i
          pages_inactive = output[/Pages inactive:\s+(\d+)/, 1].to_i
          
          # MacOS page size is typically 4096 bytes
          (pages_free + pages_inactive) * 4096
        else
          nil
        end
      rescue StandardError
        nil
      end

      def mem_used_bytes
        total = mem_total_bytes
        avail = mem_available_bytes
        return nil unless total && avail

        total - avail
      rescue StandardError
        nil
      end
    end
  end
end

