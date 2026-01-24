#!/usr/bin/env ruby
# frozen_string_literal: true

require "rbconfig"

module DeadBro
  module Collectors
    # Filesystem collector exposes disk usage information using a best-effort
    # approach. It prefers Ruby or Sys::Filesystem APIs when available and
    # falls back to parsing `df` output.
    module Filesystem
      module_function

      def collect
        paths = disk_paths
        return {paths: []} if paths.nil? || paths.empty?

        {
          paths: paths.map { |path| stats_for_path(path) }.compact
        }
      rescue => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      def disk_paths
        if DeadBro.configuration.respond_to?(:disk_paths)
          DeadBro.configuration.disk_paths || ["/"]
        else
          ["/"]
        end
      rescue
        ["/"]
      end

      def stats_for_path(path)
        if defined?(Sys::Filesystem)
          sys_filesystem_stats(path)
        else
          df_stats(path)
        end
      rescue
        nil
      end

      def sys_filesystem_stats(path)
        stat = Sys::Filesystem.stat(path)
        {
          path: path,
          disk_total_bytes: stat.blocks * stat.block_size,
          disk_free_bytes: stat.blocks_available * stat.block_size,
          disk_available_bytes: stat.blocks_available * stat.block_size
        }
      rescue
        nil
      end

      def df_stats(path)
        # Use POSIX df when available. Output format varies slightly by platform,
        # but we only depend on total and available in blocks.
        output = `df -k #{Shellwords.escape(path)} 2>/dev/null`
        lines = output.to_s.split("\n")
        return nil if lines.size < 2

        lines[0]
        data = lines[1]
        parts = data.split
        # POSIX df: Filesystem 1K-blocks Used Available Use% Mounted on
        total_kb = begin
          Integer(parts[1])
        rescue
          nil
        end
        avail_kb = begin
          Integer(parts[3])
        rescue
          nil
        end
        return nil unless total_kb && avail_kb

        {
          path: path,
          disk_total_bytes: total_kb * 1024,
          disk_free_bytes: avail_kb * 1024,
          disk_available_bytes: avail_kb * 1024
        }
      rescue
        nil
      end
    end
  end
end
