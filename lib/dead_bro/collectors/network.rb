#!/usr/bin/env ruby
# frozen_string_literal: true

require "rbconfig"

module DeadBro
  module Collectors
    # Network collector exposes best-effort rx/tx byte counters and
    # per-interval rates for Linux systems via /proc/net/dev.
    module Network
      module_function

      SAMPLE_KEY = "network".freeze

      def collect
        if linux? && File.readable?("/proc/net/dev")
          current = read_interfaces_linux
        elsif macos?
          current = read_interfaces_macos
        else
          return { available: false }
        end

        return { available: false } if current.empty?

        now = current_time
        prev = SampleStore.load(SAMPLE_KEY)
        SampleStore.save(SAMPLE_KEY, { "timestamp" => now, "interfaces" => current })

        # Filter to keep only the top interface by total activity (rx + tx)
        top_interface = current.max_by do |_, data|
          (data["rx_bytes"] || 0) + (data["tx_bytes"] || 0)
        end

        # current is a Hash: { "eth0" => { ... }, ... }
        # top_interface is an Array: ["eth0", { ... }] or nil
        
        filtered_current = {}
        filtered_current[top_interface[0]] = top_interface[1] if top_interface

        # Save *all* current interfaces to store for continuity, 
        # but only report the top one to the backend.
        # Actually, if we switch top interface, we need history for the new one.
        # So we should save all, but only return one.
        
        {
          available: true,
          interfaces: build_interface_stats(prev, filtered_current, now)
        }
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
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

      def current_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.now.to_f
      end

      def ignore_interfaces
        if DeadBro.configuration.respond_to?(:interfaces_ignore)
          DeadBro.configuration.interfaces_ignore || default_ignore
        else
          default_ignore
        end
      rescue StandardError
        default_ignore
      end

      def default_ignore
        %w[lo lo0 docker0]
      end

      def read_interfaces_linux
        ignored = ignore_interfaces
        interfaces = {}

        File.foreach("/proc/net/dev") do |line|
          next unless line.include?(":")

          name, data = line.split(":", 2)
          name = name.strip
          next if ignored.include?(name)

          fields = data.split
          # /proc/net/dev format:
          # Inter-|   Receive                                                |  Transmit
          #  face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
          rx_bytes = Integer(fields[0]) rescue nil
          tx_bytes = Integer(fields[8]) rescue nil
          next unless rx_bytes && tx_bytes

          interfaces[name] = {
            "rx_bytes" => rx_bytes,
            "tx_bytes" => tx_bytes
          }
        end

        interfaces
      rescue StandardError
        {}
      end

      def read_interfaces_macos
        ignored = ignore_interfaces
        interfaces = {}

        # netstat -ib output format (simplified):
        # Name  Mtu   Network       Address            Ipkts Ierrs    Ibytes    Opkts Oerrs     Obytes  Coll
        # lo0   16384 <Link#1>                        309756     0  49057632   309756     0   49057632     0
        # en0   1500  <Link#4>    88:66:5a:00:22:11  2685232     0 3123456789  1501234     0 234567890     0

        output = `netstat -ib`
        output.each_line do |line|
          fields = line.split
          next if fields.size < 10 # heuristic check for header or malformed line
          
          name = fields[0]
          network = fields[2]
          network = fields[2]

          # We only care about lines with <Link#...> which contain the byte counters
          next unless network && network.start_with?("<Link#")
          next if ignored.include?(name)

          # Header columns: Name(0) Mtu(1) Network(2) Address(3) Ipkts(4) Ierrs(5) Ibytes(6) Opkts(7) Oerrs(8) Obytes(9) Coll(10)
          # Note: Address column might be missing if no MAC address (like lo0), checking field alignment
          # netstat -ib alignment is tricky, sometimes space separated. 
          # Assuming standard output where <Link#..> is present:
          
          # For <Link#...> lines:
          # Name  Mtu   Network    Address            Ipkts Ierrs Ibytes    ...
          # en0   1500  <Link#4>   88:66:5a:00:22:11  ...   ...   bytes(6)  ... bytes(9)
          # lo0   16384 <Link#1>                      ...   ...   bytes(5?) -> No address column for lo0 link row?
          # Let's re-verify netstat -ib output.
          # Actually "Address" column exists for links, usually MAC address for en0, empty/implied for lo0?
          # Wait, regex is safer.
          
          # Try to identify based on identifying the Network column being <Link...>
          
          # Usually: 
          # fields[0] = Name
          # ...
          # fields[2] = <Link#...>
          # ...
          # We need to find Ibytes and Obytes. 
          # If Address is present (MAC), Ibytes is at index 6, Obytes at 9.
          # If Address is NOT present (?), indices shift? 
          # Actually netstat -ib usually aligns content.
          
          # Let's count from the end? 
          # Typical line: en0 1500 <Link#4> 88:66:5a:... 2685232 0 3123456789 1501234 0 234567890 0
          # fields: [en0, 1500, <Link#4>, MAC, Ipkts, Ierrs, Ibytes, Opkts, Oerrs, Obytes, Coll] -> 11 fields
          # Ibytes = 6, Obytes = 9
          
          # lo0 line: lo0 16384 <Link#1> 309756 0 49057632 309756 0 49057632 0
          # fields: [lo0, 16384, <Link#1>, Ipkts, Ierrs, Ibytes, Opkts, Oerrs, Obytes, Coll] -> 10 fields? Address missing?
          # Yes, lo0 often has no address in Link row.
          # Ibytes = 5, Obytes = 8
          
          # Logic:
          # if fields[3] looks like a MAC address, use 6 and 9.
          # else (assuming it's Ipkts), use 5 and 8.
          
          # Actually, Ipkts is always an integer. MAC is xx:xx:xx...
          
          idx_ibytes = 6
          idx_obytes = 9
          
          if fields[3] =~ /^\d+$/ # Field 3 is Ipkts (integer) -> Address column missing
             idx_ibytes = 5
             idx_obytes = 8
          end

          rx_bytes = Integer(fields[idx_ibytes]) rescue nil
          tx_bytes = Integer(fields[idx_obytes]) rescue nil

          next unless rx_bytes && tx_bytes

          interfaces[name] = {
            "rx_bytes" => rx_bytes,
            "tx_bytes" => tx_bytes
          }
        end

        interfaces
      rescue StandardError
        {}
      end

      def build_interface_stats(prev, current, now)
        prev_ts = prev && prev["timestamp"]
        elapsed = prev_ts ? (now - prev_ts.to_f) : nil

        current.map do |name, data|
          prev_data = prev && prev["interfaces"] && prev["interfaces"][name]
          rx_rate = tx_rate = nil

          if elapsed && elapsed > 0 && prev_data
            rx_delta = data["rx_bytes"] - prev_data["rx_bytes"].to_i
            tx_delta = data["tx_bytes"] - prev_data["tx_bytes"].to_i
            rx_rate = (rx_delta / elapsed.to_f).round(2) if rx_delta >= 0
            tx_rate = (tx_delta / elapsed.to_f).round(2) if tx_delta >= 0
          end

          {
            name: name,
            rx_bytes: data["rx_bytes"],
            tx_bytes: data["tx_bytes"],
            rx_bytes_per_s: rx_rate,
            tx_bytes_per_s: tx_rate
          }
        end
      rescue StandardError
        []
      end
    end
  end
end

