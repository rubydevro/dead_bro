#!/usr/bin/env ruby
# frozen_string_literal: true

require "time"

module DeadBro
  module Collectors
    # Jobs collector is responsible for building the unified "jobs" payload
    # that the background job queue monitor sends once per interval.
    #
    # It encapsulates queue backend detection (Sidekiq, SolidQueue, etc.)
    # and enriches the payload with optional database, process, and system
    # statistics.
    module Jobs
      module_function

      # Public entry point: returns a single Hash suitable for JSON encoding.
      def collect
        queue_system = detect_queue_system

        payload = {
          queue_system: queue_system
        }

        # Queue backend–specific stats
        payload[:queue] = collect_sidekiq_stats if queue_system == :sidekiq
        payload[:queue] = collect_solid_queue_stats if queue_system == :solid_queue
        payload[:queue] = collect_delayed_job_stats if queue_system == :delayed_job
        payload[:queue] = collect_good_job_stats if queue_system == :good_job

        # Optional collectors moved to Monitor


        payload
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      # --- Queue system detection -------------------------------------------------

      def detect_queue_system
        return :sidekiq if defined?(Sidekiq)
        return :solid_queue if defined?(SolidQueue)
        return :delayed_job if defined?(Delayed::Job)
        return :good_job if defined?(GoodJob)
        :unknown
      end

      # --- Sidekiq collector ------------------------------------------------------

      def collect_sidekiq_stats
        return {} unless defined?(Sidekiq)

        stats = {
          processed: nil,
          failed: nil,
          enqueued: nil,
          scheduled_size: nil,
          retry_size: nil,
          dead_size: nil,
          workers_size: nil,
          processes_size: nil,
          memory_rss_bytes: nil,
          queues: []
        }

        begin
          sidekiq_stats = safe_sidekiq_stats
          if sidekiq_stats
            stats[:processed]      = sidekiq_stats.processed rescue nil
            stats[:failed]         = sidekiq_stats.failed rescue nil
            stats[:enqueued]       = sidekiq_stats.enqueued rescue nil
            stats[:scheduled_size] = sidekiq_stats.scheduled_size rescue nil
            stats[:retry_size]     = sidekiq_stats.retry_size rescue nil
            stats[:dead_size]      = sidekiq_stats.dead_size rescue nil
            stats[:workers_size]   = sidekiq_stats.workers_size rescue nil
            stats[:processes_size] = sidekiq_stats.processes_size rescue nil
          end

          # Per-queue size and latency
          queue_class = Sidekiq.const_get(:Queue) rescue nil
          if queue_class && queue_class.respond_to?(:all)
            queue_class.all.each do |queue|
              stats[:queues] << {
                name: queue.name,
                size: safe_integer(queue.size),
                latency_s: safe_latency(queue)
              }
            end
          end

          # Process RSS at collection time (best-effort)
          if DeadBro.configuration.respond_to?(:enable_process_stats) && DeadBro.configuration.enable_process_stats
            stats[:memory_rss_bytes] = ProcessInfo.rss_bytes rescue nil
          end
        rescue StandardError => e
          stats[:error_class] = e.class.name
          stats[:error_message] = e.message.to_s[0, 500]
        end

        stats
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      def safe_sidekiq_stats
        require "sidekiq/api"
        Sidekiq::Stats.new
      rescue LoadError, NameError, StandardError
        nil
      end

      def safe_integer(value)
        Integer(value)
      rescue StandardError
        nil
      end

      def safe_latency(queue)
        latency = queue.latency rescue nil
        return nil unless latency

        value = Float(latency) rescue nil
        return nil unless value && value.finite?

        value
      rescue StandardError
        nil
      end

      # --- SolidQueue collector (database-backed) ---------------------------------

      def collect_solid_queue_stats
        return {} unless defined?(SolidQueue)
        return {} unless defined?(ActiveRecord)
        return {} unless ActiveRecord::Base.respond_to?(:connected?) && ActiveRecord::Base.connected?

        stats = { total_queued: 0, total_busy: 0, queues: {} }

        begin
          conn = ActiveRecord::Base.connection
          return stats unless conn.respond_to?(:table_exists?) && conn.table_exists?("solid_queue_jobs")

          # queued jobs
          result = conn.execute("SELECT queue_name, COUNT(*) as count FROM solid_queue_jobs WHERE finished_at IS NULL GROUP BY queue_name")
          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] = { queued: count, busy: 0, scheduled: 0, retries: 0 }
            stats[:total_queued] += count
          end

          # busy jobs
          result = conn.execute("SELECT queue_name, COUNT(*) as count FROM solid_queue_jobs WHERE finished_at IS NULL AND claimed_at IS NOT NULL GROUP BY queue_name")
          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] ||= { queued: 0, busy: 0, scheduled: 0, retries: 0 }
            stats[:queues][queue_name][:busy] = count
            stats[:total_busy] += count
          end

          # scheduled jobs
          result = conn.execute("SELECT COUNT(*) as count FROM solid_queue_jobs WHERE scheduled_at > NOW()")
          scheduled_count = parse_query_result(result).first
          stats[:total_scheduled] = (scheduled_count&.dig("count") || scheduled_count&.dig(:count) || 0).to_i

          # failed jobs
          if conn.table_exists?("solid_queue_failed_jobs")
            result = conn.execute("SELECT COUNT(*) as count FROM solid_queue_failed_jobs")
            failed_count = parse_query_result(result).first
            stats[:total_failed] = (failed_count&.dig("count") || failed_count&.dig(:count) || 0).to_i
          end
        rescue StandardError => e
          stats[:error_class] = e.class.name
          stats[:error_message] = e.message.to_s[0, 500]
        end

        stats
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      # --- Delayed::Job collector -------------------------------------------------

      def collect_delayed_job_stats
        return {} unless defined?(Delayed::Job)
        return {} unless defined?(ActiveRecord)

        stats = { total_queued: 0, total_busy: 0, queues: {} }

        begin
          return stats unless ActiveRecord::Base.connection.table_exists?("delayed_jobs")

          # queued jobs
          queued = Delayed::Job.where("locked_at IS NULL AND attempts < max_attempts").count
          stats[:total_queued] = queued
          stats[:queues]["default"] = { queued: queued, busy: 0, scheduled: 0, retries: 0 }

          # busy jobs
          busy = Delayed::Job.where("locked_at IS NOT NULL AND locked_by IS NOT NULL").count
          stats[:total_busy] = busy
          stats[:queues]["default"][:busy] = busy

          # failed jobs
          failed = Delayed::Job.where("attempts >= max_attempts").count
          stats[:total_failed] = failed
        rescue StandardError => e
          stats[:error_class] = e.class.name
          stats[:error_message] = e.message.to_s[0, 500]
        end

        stats
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      # --- GoodJob collector ------------------------------------------------------

      def collect_good_job_stats
        return {} unless defined?(GoodJob)
        return {} unless defined?(ActiveRecord)
        return {} unless ActiveRecord::Base.respond_to?(:connected?) && ActiveRecord::Base.connected?

        stats = { total_queued: 0, total_busy: 0, queues: {} }

        begin
          conn = ActiveRecord::Base.connection
          return stats unless conn.respond_to?(:table_exists?) && conn.table_exists?("good_jobs")

          # queued
          result = conn.execute("SELECT queue_name, COUNT(*) as count FROM good_jobs WHERE finished_at IS NULL GROUP BY queue_name")
          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] = { queued: count, busy: 0, scheduled: 0, retries: 0 }
            stats[:total_queued] += count
          end

          # busy
          result = conn.execute("SELECT queue_name, COUNT(*) as count FROM good_jobs WHERE finished_at IS NULL AND performed_at IS NOT NULL GROUP BY queue_name")
          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] ||= { queued: 0, busy: 0, scheduled: 0, retries: 0 }
            stats[:queues][queue_name][:busy] = count
            stats[:total_busy] += count
          end

          # scheduled
          result = conn.execute("SELECT COUNT(*) as count FROM good_jobs WHERE scheduled_at > NOW()")
          scheduled_count = parse_query_result(result).first
          stats[:total_scheduled] = (scheduled_count&.dig("count") || scheduled_count&.dig(:count) || 0).to_i

          # failed
          result = conn.execute("SELECT COUNT(*) as count FROM good_jobs WHERE finished_at IS NOT NULL AND error IS NOT NULL")
          failed_count = parse_query_result(result).first
          stats[:total_failed] = (failed_count&.dig("count") || failed_count&.dig(:count) || 0).to_i
        rescue StandardError => e
          stats[:error_class] = e.class.name
          stats[:error_message] = e.message.to_s[0, 500]
        end

        stats
      rescue StandardError => e
        {
          error_class: e.class.name,
          error_message: e.message.to_s[0, 500]
        }
      end

      # --- Shared helpers ---------------------------------------------------------

      def parse_query_result(result)
        if result.respond_to?(:each)
          if result.respond_to?(:values)
            columns = result.fields rescue result.column_names rescue []
            result.values.map do |row|
              columns.each_with_index.each_with_object({}) do |(col, idx), hash|
                hash[col.to_s] = row[idx]
                hash[col.to_sym] = row[idx]
              end
            end
          elsif result.is_a?(Array)
            result
          else
            result.to_a
          end
        else
          []
        end
      rescue StandardError
        []
      end

      def safe_app_name
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.class.module_parent_name rescue Rails.application.class.name
        else
          nil
        end
      rescue StandardError
        nil
      end

      def process_hostname
        if defined?(ProcessInfo)
          ProcessInfo.safe_hostname rescue default_hostname
        else
          default_hostname
        end
      rescue StandardError
        default_hostname
      end

      def default_hostname
        require "socket"
        Socket.gethostname
      rescue StandardError
        "unknown"
      end

      def safe_collect
        yield
      rescue StandardError => e
        { error_class: e.class.name, error_message: e.message.to_s[0, 500] }
      end
    end
  end
end

