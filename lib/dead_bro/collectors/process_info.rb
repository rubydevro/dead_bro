#!/usr/bin/env ruby
# frozen_string_literal: true

require "rbconfig"
require "socket"

module DeadBro
  module Collectors
    # ProcessInfo collector exposes Ruby / Rails / process level metrics such as
    # RSS, thread count, file descriptor count, GC stats and uptime.
    #
    # All methods are best-effort and will return nil on failure rather than
    # raising exceptions.
    module ProcessInfo
      module_function

      def collect
        now = Time.now.utc

        {
          kind: DeadBro.process_kind,
          pid: Process.pid,
          hostname: safe_hostname,
          boot_time: rails_boot_time,
          uptime_s: uptime_seconds(now),
          ruby_version: RUBY_VERSION,
          rails_version: safe_rails_version,
          app_env: DeadBro.env,
          rss_bytes: rss_bytes,
          thread_count: thread_count,
          fd_count: fd_count,
          gc: gc_stats
        }
      rescue => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      def linux?
        host_os = RbConfig::CONFIG["host_os"].to_s.downcase
        host_os.include?("linux")
      rescue
        false
      end

      def macos?
        host_os = RbConfig::CONFIG["host_os"].to_s.downcase
        host_os.include?("darwin")
      rescue
        false
      end

      def safe_hostname
        Socket.gethostname
      rescue
        "unknown"
      end

      def rails_boot_time
        return nil unless defined?(Rails)

        if Rails.respond_to?(:application) && Rails.application.respond_to?(:config)
          # Rails does not expose boot time directly; approximate with process start
          process_start_time
        else
          process_start_time
        end
      rescue
        nil
      end

      def process_start_time
        @process_start_time ||= Time.now.utc
      end

      def uptime_seconds(now = Time.now.utc)
        (now.to_f - process_start_time.to_f).round(2)
      rescue
        nil
      end

      def safe_rails_version
        if defined?(Rails) && Rails.respond_to?(:version)
          Rails.version
        elsif defined?(Rails::VERSION) && Rails::VERSION::STRING
          Rails::VERSION::STRING
        end
      rescue
        nil
      end

      def rss_bytes
        if linux? && File.readable?("/proc/self/status")
          parse_proc_status_for_rss("/proc/self/status")
        else
          rss_from_ps
        end
      rescue
        nil
      end

      def parse_proc_status_for_rss(path)
        File.foreach(path) do |line|
          next unless line.start_with?("VmRSS:")

          parts = line.split
          value_kb = begin
            Integer(parts[1])
          rescue
            nil
          end
          return value_kb * 1024 if value_kb
        end
        nil
      rescue
        nil
      end

      def rss_from_ps
        rss_kb = `ps -o rss= -p #{Process.pid}`.to_i
        return nil if rss_kb <= 0

        rss_kb * 1024
      rescue
        nil
      end

      def thread_count
        if linux? && File.readable?("/proc/self/status")
          File.foreach("/proc/self/status") do |line|
            next unless line.start_with?("Threads:")

            parts = line.split
            begin
              return Integer(parts[1])
            rescue
              nil
            end
          end
          nil
        else
          Thread.list.size
        end
      rescue
        nil
      end

      def fd_count
        if linux? && File.directory?("/proc/self/fd")
          Dir.entries("/proc/self/fd").size - 2 # exclude . and ..
        elsif macos? && File.directory?("/dev/fd")
          Dir.entries("/dev/fd").size - 2
        else
          # Best-effort: count file descriptors under /proc when available
          nil
        end
      rescue
        nil
      end

      def gc_stats
        return {} unless defined?(GC) && GC.respond_to?(:stat)

        stats = GC.stat
        {
          heap_live_slots: stats[:heap_live_slots],
          heap_free_slots: stats[:heap_free_slots],
          total_allocated_objects: stats[:total_allocated_objects],
          major_gc_count: stats[:major_gc_count],
          minor_gc_count: stats[:minor_gc_count]
        }
      rescue
        {}
      end
    end
  end
end
