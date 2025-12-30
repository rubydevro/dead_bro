# frozen_string_literal: true

begin
  require "active_support/notifications"
rescue LoadError
  # ActiveSupport not available
end

module DeadBro
  class JobSubscriber
    JOB_EVENT_NAME = "perform.active_job"
    JOB_EXCEPTION_EVENT_NAME = "exception.active_job"

    def self.subscribe!(client: Client.new)
      # Track job execution
      ActiveSupport::Notifications.subscribe(JOB_EVENT_NAME) do |name, started, finished, _unique_id, data|
        begin
          job_class_name = data[:job].class.name
          if DeadBro.configuration.excluded_job?(job_class_name)
            next
          end
          # If exclusive_jobs is defined and not empty, only track matching jobs
          unless DeadBro.configuration.exclusive_job?(job_class_name)
            next
          end
        rescue
        end

        duration_ms = ((finished - started) * 1000.0).round(2)

        # Get SQL queries executed during this job
        sql_queries = DeadBro::SqlSubscriber.stop_request_tracking

        # Stop memory tracking and get collected memory data
        if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
          detailed_memory = DeadBro::MemoryTrackingSubscriber.stop_request_tracking
          memory_performance = DeadBro::MemoryTrackingSubscriber.analyze_memory_performance(detailed_memory)
          # Keep memory_events compact and user-friendly (no large raw arrays)
          memory_events = {
            memory_before: detailed_memory[:memory_before],
            memory_after: detailed_memory[:memory_after],
            duration_seconds: detailed_memory[:duration_seconds],
            allocations_count: (detailed_memory[:allocations] || []).length,
            memory_snapshots_count: (detailed_memory[:memory_snapshots] || []).length,
            large_objects_count: (detailed_memory[:large_objects] || []).length
          }
        else
          lightweight_memory = DeadBro::LightweightMemoryTracker.stop_request_tracking
          # Separate raw readings from derived performance metrics to avoid duplicating data
          memory_events = {
            memory_before: lightweight_memory[:memory_before],
            memory_after: lightweight_memory[:memory_after]
          }
          memory_performance = {
            memory_growth_mb: lightweight_memory[:memory_growth_mb],
            gc_count_increase: lightweight_memory[:gc_count_increase],
            heap_pages_increase: lightweight_memory[:heap_pages_increase],
            duration_seconds: lightweight_memory[:duration_seconds]
          }
        end

        payload = {
          job_class: data[:job].class.name,
          job_id: data[:job].job_id,
          queue_name: data[:job].queue_name,
          arguments: safe_arguments(data[:job].arguments),
          duration_ms: duration_ms,
          status: "completed",
          sql_queries: sql_queries,
          rails_env: safe_rails_env,
          host: safe_host,
          memory_usage: memory_usage_mb,
          gc_stats: gc_stats,
          memory_events: memory_events,
          memory_performance: memory_performance,
          logs: DeadBro.logger.logs
        }

        client.post_metric(event_name: name, payload: payload)
      end

      # Track job exceptions
      ActiveSupport::Notifications.subscribe(JOB_EXCEPTION_EVENT_NAME) do |name, started, finished, _unique_id, data|
        begin
          job_class_name = data[:job].class.name
          if DeadBro.configuration.excluded_job?(job_class_name)
            next
          end
          # If exclusive_jobs is defined and not empty, only track matching jobs
          unless DeadBro.configuration.exclusive_job?(job_class_name)
            next
          end
        rescue
        end

        duration_ms = ((finished - started) * 1000.0).round(2)
        exception = data[:exception_object]

        # Get SQL queries executed during this job
        sql_queries = DeadBro::SqlSubscriber.stop_request_tracking

        # Stop memory tracking and get collected memory data
        if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
          detailed_memory = DeadBro::MemoryTrackingSubscriber.stop_request_tracking
          memory_performance = DeadBro::MemoryTrackingSubscriber.analyze_memory_performance(detailed_memory)
          # Keep memory_events compact and user-friendly (no large raw arrays)
          memory_events = {
            memory_before: detailed_memory[:memory_before],
            memory_after: detailed_memory[:memory_after],
            duration_seconds: detailed_memory[:duration_seconds],
            allocations_count: (detailed_memory[:allocations] || []).length,
            memory_snapshots_count: (detailed_memory[:memory_snapshots] || []).length,
            large_objects_count: (detailed_memory[:large_objects] || []).length
          }
        else
          lightweight_memory = DeadBro::LightweightMemoryTracker.stop_request_tracking
          # Separate raw readings from derived performance metrics to avoid duplicating data
          memory_events = {
            memory_before: lightweight_memory[:memory_before],
            memory_after: lightweight_memory[:memory_after]
          }
          memory_performance = {
            memory_growth_mb: lightweight_memory[:memory_growth_mb],
            gc_count_increase: lightweight_memory[:gc_count_increase],
            heap_pages_increase: lightweight_memory[:heap_pages_increase],
            duration_seconds: lightweight_memory[:duration_seconds]
          }
        end

        payload = {
          job_class: data[:job].class.name,
          job_id: data[:job].job_id,
          queue_name: data[:job].queue_name,
          arguments: safe_arguments(data[:job].arguments),
          duration_ms: duration_ms,
          status: "failed",
          sql_queries: sql_queries,
          exception_class: exception&.class&.name,
          message: exception&.message&.to_s&.[](0, 1000),
          backtrace: Array(exception&.backtrace).first(50),
          rails_env: safe_rails_env,
          host: safe_host,
          memory_usage: memory_usage_mb,
          gc_stats: gc_stats,
          memory_events: memory_events,
          memory_performance: memory_performance,
          logs: DeadBro.logger.logs
        }

        event_name = exception&.class&.name || "ActiveJob::Exception"
        client.post_metric(event_name: event_name, payload: payload, error: true)
      end
    rescue
      # Never raise from instrumentation install
    end

    private

    def self.safe_arguments(arguments)
      return [] unless arguments.is_a?(Array)

      # Limit and sanitize job arguments
      arguments.first(10).map do |arg|
        case arg
        when String
          (arg.length > 200) ? arg[0, 200] + "..." : arg
        when Hash
          # Filter sensitive keys and limit size
          filtered = arg.except(*%w[password token secret key])
          (filtered.keys.size > 20) ? filtered.first(20).to_h : filtered
        when Array
          arg.first(5)
        when ActiveRecord::Base
          # Handle ActiveRecord objects safely
          "#{arg.class.name}##{begin
            arg.id
          rescue
            "unknown"
          end}"
        else
          # Convert to string and truncate, but avoid object inspection
          (arg.to_s.length > 200) ? arg.to_s[0, 200] + "..." : arg.to_s
        end
      end
    rescue
      []
    end

    def self.safe_rails_env
      if defined?(Rails) && Rails.respond_to?(:env)
        Rails.env
      else
        ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
      end
    rescue
      "development"
    end

    def self.safe_host
      if defined?(Rails) && Rails.respond_to?(:application)
        begin
          Rails.application.class.module_parent_name
        rescue
          ""
        end
      else
        ""
      end
    end

    def self.memory_usage_mb
      if defined?(GC) && GC.respond_to?(:stat)
        # Get memory usage in MB
        memory_kb = begin
          `ps -o rss= -p #{Process.pid}`.to_i
        rescue
          0
        end
        (memory_kb / 1024.0).round(2)
      else
        0
      end
    rescue
      0
    end

    def self.gc_stats
      if defined?(GC) && GC.respond_to?(:stat)
        stats = GC.stat
        {
          count: stats[:count] || 0,
          heap_allocated_pages: stats[:heap_allocated_pages] || 0,
          heap_sorted_pages: stats[:heap_sorted_pages] || 0,
          total_allocated_objects: stats[:total_allocated_objects] || 0
        }
      else
        {}
      end
    rescue
      {}
    end
  end
end
