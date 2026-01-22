#!/usr/bin/env ruby
# frozen_string_literal: true

module DeadBro
  module Collectors
    # Database collector provides lightweight, best-effort information
    # about the current ActiveRecord connection pool and a simple ping
    # latency measurement.
    module Database
      module_function

      def collect
        return { disabled: true } unless db_enabled?
        return { available: false } unless defined?(::ActiveRecord)

        base = ::ActiveRecord::Base
        return { available: false } unless base.respond_to?(:connection_pool) && base.connection_pool

        pool = safe_connection_pool(base)

        payload = {
          available: true,
          pool: pool_stats(pool),
          ping_ms: ping_ms(base)
        }

        payload
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      def db_enabled?
        DeadBro.configuration.respond_to?(:enable_db_stats) &&
          DeadBro.configuration.enable_db_stats
      rescue StandardError
        false
      end

      def safe_connection_pool(base)
        if base.respond_to?(:connection_pool)
          base.connection_pool
        elsif base.respond_to?(:connection_handler)
          base.connection_handler.retrieve_connection_pool(base) rescue nil
        end
      rescue StandardError
        nil
      end

      def pool_stats(pool)
        return {} unless pool

        {
          size:           (safe_integer(pool.size) rescue nil),
          connections:    (safe_integer(pool.connections.size) rescue nil),
          busy:           (safe_integer(pool.respond_to?(:busy) ? pool.busy : nil) rescue nil),
          dead:           (safe_integer(pool.respond_to?(:dead) ? pool.dead : nil) rescue nil),
          num_waiting:    (safe_integer(pool.respond_to?(:num_waiting) ? pool.num_waiting : nil) rescue nil),
          automatic_reconnect: pool.respond_to?(:automatic_reconnect) ? !!pool.automatic_reconnect : nil
        }
      rescue StandardError
        {}
      end

      def ping_ms(base)
        started = current_time
        base.connection_pool.with_connection do |conn|
          sql = case conn.adapter_name.to_s.downcase
                when /mysql/
                  "SELECT 1"
                when /sqlite/
                  "SELECT 1"
                else
                  "SELECT 1"
                end
          conn.select_value(sql)
        end
        elapsed_ms(started)
      rescue StandardError
        nil
      end

      def current_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.now.to_f
      end

      def elapsed_ms(started)
        ((current_time - started) * 1000.0).round(2)
      rescue StandardError
        nil
      end

      def safe_integer(value)
        Integer(value)
      rescue StandardError
        nil
      end
    end
  end
end

