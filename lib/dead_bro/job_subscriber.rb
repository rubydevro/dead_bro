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
      # Snap GC state before the job runs so stop_request_tracking gets a valid diff
      ActiveSupport::Notifications.subscribe("perform_start.active_job") do |_name, _started, _finished, _unique_id, _data|
        DeadBro::GcTracker.start_request_tracking if defined?(DeadBro::GcTracker)
        DeadBro::ArObjectTracker.start_request_tracking if defined?(DeadBro::ArObjectTracker)
      rescue
      end

      # Track job execution
      ActiveSupport::Notifications.subscribe(JOB_EVENT_NAME) do |name, started, finished, _unique_id, data|
        begin
          if DeadBro.configuration.skip_tracking?
            drain_job_tracking
            next
          end

          job_class_name = data[:job].class.name
          if DeadBro.configuration.excluded_job?(job_class_name)
            drain_job_tracking
            next
          end
          # If exclusive_jobs is defined and not empty, only track matching jobs
          unless DeadBro.configuration.exclusive_job?(job_class_name)
            drain_job_tracking
            next
          end
        rescue
        end

        # Skip out via sampling before we build any payload — jobs can be chatty
        # enough that even the "cheap" stop/analyze work matters under load.
        # Completions have no exception attached; the exception subscriber below
        # always sends errors with force: true.
        job_type_key = "#{job_class_name}#perform"
        unless DeadBro.configuration.should_sample?(job_type_key)
          drain_job_tracking
          next
        end

        duration_ms = ((finished - started) * 1000.0).round(2)
        queue_duration_ms = job_queue_duration_ms(data[:job], started)

        # Ensure tracking was started (fallback if perform_start.active_job didn't fire)
        # This handles job backends that don't emit perform_start events
        unless DeadBro::SqlSubscriber.tracking_active?
          DeadBro.logger.clear
          Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now
          DeadBro::SqlSubscriber.start_request_tracking
          start_job_dependency_tracking
          DeadBro::DbConnectionSubscriber.start_request_tracking if defined?(DeadBro::DbConnectionSubscriber)
          DeadBro::WatchTracker.start_request_tracking if defined?(DeadBro::WatchTracker)
          if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
            DeadBro::MemoryTrackingSubscriber.start_request_tracking
          else
            DeadBro::LightweightMemoryTracker.start_request_tracking if defined?(DeadBro::LightweightMemoryTracker)
          end
        end

        # Get SQL queries executed during this job
        sql_queries = DeadBro::SqlSubscriber.stop_request_tracking
        dependency_events = job_dependency_payload
        db_connection_stats = defined?(DeadBro::DbConnectionSubscriber) ? DeadBro::DbConnectionSubscriber.stop_request_tracking : {}
        gc_pressure = defined?(DeadBro::GcTracker) ? DeadBro::GcTracker.stop_request_tracking : {}
        ar_instantiation_count = defined?(DeadBro::ArObjectTracker) ? DeadBro::ArObjectTracker.stop_request_tracking : nil
        watch_events = defined?(DeadBro::WatchTracker) ? DeadBro::WatchTracker.stop_request_tracking : []

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
          started_at: started.utc.iso8601(3),
          duration_ms: duration_ms,
          queue_duration_ms: queue_duration_ms,
          db_connection_wait_ms: db_connection_stats[:wait_ms],
          db_connection_checkouts: db_connection_stats[:checkouts],
          gc_pressure: gc_pressure,
          ar_instantiation_count: ar_instantiation_count,
          status: "completed",
          sql_queries: sql_queries,
          rails_env: DeadBro.env,
          host: DeadBro.safe_hostname,
          process_kind: DeadBro.process_kind,
          memory_usage: memory_usage_mb,
          gc_stats: gc_stats,
          memory_events: memory_events,
          memory_performance: memory_performance,
          watch_events: watch_events,
          logs: DeadBro.logger.logs
        }.merge(dependency_events)

        # force: true — the sampling decision above already accounted for any
        # per-job-type override; client#post_metric must not re-roll it globally.
        client.post_metric(event_name: name, payload: payload, force: true)
      end

      # Track job exceptions
      ActiveSupport::Notifications.subscribe(JOB_EXCEPTION_EVENT_NAME) do |name, started, finished, _unique_id, data|
        begin
          if DeadBro.configuration.skip_tracking?
            drain_job_tracking
            next
          end

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
        queue_duration_ms = job_queue_duration_ms(data[:job], started)

        # Ensure tracking was started (fallback if perform_start.active_job didn't fire)
        unless DeadBro::SqlSubscriber.tracking_active?
          DeadBro.logger.clear
          Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now
          DeadBro::SqlSubscriber.start_request_tracking
          start_job_dependency_tracking
          DeadBro::DbConnectionSubscriber.start_request_tracking if defined?(DeadBro::DbConnectionSubscriber)
          DeadBro::WatchTracker.start_request_tracking if defined?(DeadBro::WatchTracker)
          if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
            DeadBro::MemoryTrackingSubscriber.start_request_tracking
          else
            DeadBro::LightweightMemoryTracker.start_request_tracking if defined?(DeadBro::LightweightMemoryTracker)
          end
        end

        # Get SQL queries executed during this job
        sql_queries = DeadBro::SqlSubscriber.stop_request_tracking
        dependency_events = job_dependency_payload
        db_connection_stats = defined?(DeadBro::DbConnectionSubscriber) ? DeadBro::DbConnectionSubscriber.stop_request_tracking : {}
        gc_pressure = defined?(DeadBro::GcTracker) ? DeadBro::GcTracker.stop_request_tracking : {}
        ar_instantiation_count = defined?(DeadBro::ArObjectTracker) ? DeadBro::ArObjectTracker.stop_request_tracking : nil
        watch_events = defined?(DeadBro::WatchTracker) ? DeadBro::WatchTracker.stop_request_tracking : []

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
          started_at: started.utc.iso8601(3),
          duration_ms: duration_ms,
          queue_duration_ms: queue_duration_ms,
          db_connection_wait_ms: db_connection_stats[:wait_ms],
          db_connection_checkouts: db_connection_stats[:checkouts],
          gc_pressure: gc_pressure,
          ar_instantiation_count: ar_instantiation_count,
          status: "failed",
          sql_queries: sql_queries,
          exception_class: exception&.class&.name,
          message: exception&.message&.to_s&.[](0, 1000),
          backtrace: Array(exception&.backtrace).first(50),
          rails_env: DeadBro.env,
          host: DeadBro.safe_hostname,
          process_kind: DeadBro.process_kind,
          memory_usage: memory_usage_mb,
          gc_stats: gc_stats,
          memory_events: memory_events,
          memory_performance: memory_performance,
          watch_events: watch_events,
          logs: DeadBro.logger.logs
        }.merge(dependency_events)

        event_name = exception&.class&.name || "ActiveJob::Exception"
        client.post_metric(event_name: event_name, payload: payload, force: true)
      end
    rescue
      # Never raise from instrumentation install
    end

    # Release job-side thread-local tracking state when we've decided not to
    # build a payload (excluded job / sampled out). Matches Subscriber.drain_request_tracking.
    def self.drain_job_tracking
      # wait_for_explains: false — result is discarded, don't block on pending plans.
      DeadBro::SqlSubscriber.stop_request_tracking(wait_for_explains: false) if defined?(DeadBro::SqlSubscriber)
      Thread.current[:dead_bro_http_events] = nil
      DeadBro::CacheSubscriber.stop_request_tracking if defined?(DeadBro::CacheSubscriber)
      DeadBro::RedisSubscriber.stop_request_tracking if defined?(DeadBro::RedisSubscriber)
      DeadBro::ElasticsearchSubscriber.stop_request_tracking if defined?(DeadBro::ElasticsearchSubscriber)
      DeadBro::ViewRenderingSubscriber.stop_request_tracking if defined?(DeadBro::ViewRenderingSubscriber)
      DeadBro::DbConnectionSubscriber.stop_request_tracking if defined?(DeadBro::DbConnectionSubscriber)
      DeadBro::GcTracker.stop_request_tracking if defined?(DeadBro::GcTracker)
      DeadBro::ArObjectTracker.stop_request_tracking if defined?(DeadBro::ArObjectTracker)
      DeadBro::LightweightMemoryTracker.stop_request_tracking if defined?(DeadBro::LightweightMemoryTracker)
      if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
        DeadBro::MemoryTrackingSubscriber.stop_request_tracking
      end
      DeadBro::WatchTracker.stop_request_tracking if defined?(DeadBro::WatchTracker)
    rescue
      # Best effort
    end

    # Start HTTP/Redis/cache/view/Elasticsearch tracking for job backends that never
    # emit perform_start.active_job (so JobSqlTrackingMiddleware didn't run). Mirrors the
    # dependency tracking the middleware normally arms — see its comment for why each
    # thread-local must be initialized before its subscriber will record anything.
    def self.start_job_dependency_tracking
      Thread.current[:dead_bro_http_events] = []
      DeadBro::CacheSubscriber.start_request_tracking if defined?(DeadBro::CacheSubscriber)
      DeadBro::RedisSubscriber.start_request_tracking if defined?(DeadBro::RedisSubscriber)
      DeadBro::ElasticsearchSubscriber.start_request_tracking if defined?(DeadBro::ElasticsearchSubscriber)
      DeadBro::ViewRenderingSubscriber.start_request_tracking if defined?(DeadBro::ViewRenderingSubscriber)
    rescue
    end

    # Snapshot and clear the per-job dependency events, returning the payload slice that
    # mirrors what the web Subscriber sends. These feed the performance breakdown (the app
    # derives http/redis/es duration columns from them) and the trace timeline.
    def self.job_dependency_payload
      http_outgoing = Thread.current[:dead_bro_http_events] || []
      Thread.current[:dead_bro_http_events] = nil
      cache_events = defined?(DeadBro::CacheSubscriber) ? DeadBro::CacheSubscriber.stop_request_tracking : []
      redis_events = defined?(DeadBro::RedisSubscriber) ? DeadBro::RedisSubscriber.stop_request_tracking : []
      elasticsearch_events = defined?(DeadBro::ElasticsearchSubscriber) ? DeadBro::ElasticsearchSubscriber.stop_request_tracking : []
      view_events = defined?(DeadBro::ViewRenderingSubscriber) ? DeadBro::ViewRenderingSubscriber.stop_request_tracking : []
      view_performance = defined?(DeadBro::ViewRenderingSubscriber) ? DeadBro::ViewRenderingSubscriber.analyze_view_performance(view_events) : {}

      {
        http_outgoing: http_outgoing,
        cache_events: cache_events,
        redis_events: redis_events,
        elasticsearch_events: elasticsearch_events,
        view_events: view_events,
        view_performance: view_performance,
        view_runtime_ms: sum_view_runtime_ms(view_events)
      }
    rescue
      {}
    end

    def self.sum_view_runtime_ms(view_events)
      return nil unless view_events.is_a?(Array) && view_events.any?
      view_events.sum do |e|
        next 0 unless e.is_a?(Hash)
        (e[:total_duration_ms] || e["total_duration_ms"] || e[:duration_ms] || e["duration_ms"] || 0).to_f
      end.round(2)
    rescue
      nil
    end

    private

    def self.job_queue_duration_ms(job, perform_started)
      enqueued_at = job.enqueued_at
      return nil if enqueued_at.nil?

      enqueued_time = enqueued_at.is_a?(Time) ? enqueued_at : Time.parse(enqueued_at.to_s)
      diff_ms = ((perform_started - enqueued_time) * 1000.0).round(2)
      diff_ms >= 0 ? diff_ms : nil
    rescue
      nil
    end

    def self.safe_arguments(arguments)
      return [] unless arguments.is_a?(Array)

      # Limit and sanitize job arguments
      arguments.first(10).map do |arg|
        case arg
        when String
          (arg.length > 200) ? arg[0, 200] + "..." : arg
        when Hash
          # Filter sensitive keys and limit size
          filtered = arg.reject { |k, _| %w[password token secret key].include?(k.to_s) }
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

    def self.memory_usage_mb
      DeadBro::MemoryHelpers.rss_mb
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
