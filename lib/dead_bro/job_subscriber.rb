# frozen_string_literal: true

begin
  require "active_support/notifications"
rescue LoadError
  # ActiveSupport not available
end

module DeadBro
  class JobSubscriber
    JOB_EVENT_NAME = "perform.active_job"

    # ActiveJob instruments these from inside perform_now when retry_on or
    # discard_on takes an exception, mapped to the error_handling label the
    # failed run is reported with.
    HANDLED_ERROR_EVENTS = {
      "enqueue_retry.active_job" => "retried",
      "retry_stopped.active_job" => "retries_exhausted",
      "discard.active_job" => "discarded"
    }.freeze
    HANDLED_ERRORS_KEY = :dead_bro_job_handled_errors
    # Entries are removed when their job's perform.active_job finishes; this
    # only bounds the ones a retry_job called outside perform would leave behind.
    MAX_HANDLED_ERRORS = 100

    def self.subscribe!(client: Client.new)
      # Snap GC state before the job runs so stop_request_tracking gets a valid diff
      ActiveSupport::Notifications.subscribe("perform_start.active_job") do |_name, _started, _finished, _unique_id, data|
        handled_errors.delete(data[:job].job_id) if data[:job]
        start_gc_tracking
      rescue
      end

      # A job whose exception retry_on/discard_on handled returns normally:
      # ActiveJob::Execution#perform_now rescues it and hands it to
      # rescue_with_handler before Instrumentation's `super` returns, so
      # perform.active_job finishes with no exception attached. These events fire
      # inside that rescue, before perform.active_job finishes on this thread, so
      # the handled exception is noted here and the run reported as failed below.
      # A custom rescue_from instruments nothing and still reports "completed".
      HANDLED_ERROR_EVENTS.each do |event, handling|
        ActiveSupport::Notifications.subscribe(event) do |_name, _started, _finished, _unique_id, data|
          job = data[:job]
          error = data[:error]
          next unless job && error

          errors = handled_errors
          errors.clear if errors.size >= MAX_HANDLED_ERRORS
          errors[job.job_id] = {error: error, handling: handling}
        rescue
        end
      end

      # Track job execution — success AND failure both land here. ActiveJob wraps
      # perform with `instrument(:perform) { super }` (see
      # ActiveJob::Instrumentation#instrument), and AS::Notifications.instrument
      # still runs its "finish" listeners (with :exception / :exception_object set
      # in the payload) when the block raises, then re-raises. There is no separate
      # "exception.active_job" event anywhere in Rails/ActiveJob. Branching on
      # data[:exception_object] here is how an unhandled failure is detected; a
      # handled one was noted by the HANDLED_ERROR_EVENTS subscribers above.
      ActiveSupport::Notifications.subscribe(JOB_EVENT_NAME) do |name, started, finished, _unique_id, data|
        job = data[:job]
        handled = handled_errors.delete(job.job_id)
        report_job(
          client: client,
          event_name: name,
          job_class_name: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name,
          arguments: job.arguments,
          enqueued_at: job.enqueued_at,
          started: started,
          finished: finished,
          exception: data[:exception_object] || handled&.dig(:error),
          error_handling: handled&.dig(:handling)
        )
      rescue
        # Never raise into the job
      end
    rescue
      # Never raise from instrumentation install
    end

    def self.handled_errors
      Thread.current[HANDLED_ERRORS_KEY] ||= {}
    end

    def self.start_gc_tracking
      DeadBro::GcTracker.start_request_tracking if defined?(DeadBro::GcTracker)
      DeadBro::ArObjectTracker.start_request_tracking if defined?(DeadBro::ArObjectTracker)
    rescue
    end

    # Everything perform_start.active_job arms, for job runners that don't emit it
    # (SidekiqServerMiddleware).
    def self.start_job_tracking
      DeadBro::JobSqlTrackingMiddleware.start_tracking
      start_gc_tracking
    end

    # Builds and ships one job run's payload — from perform.active_job, or from
    # SidekiqServerMiddleware for a native Sidekiq job. exception is nil for a
    # run that completed.
    def self.report_job(client:, event_name:, job_class_name:, job_id:, queue_name:, arguments:,
      enqueued_at:, started:, finished:, exception:, error_handling: nil)
      begin
        if DeadBro.configuration.skip_tracking?
          drain_job_tracking
          return
        end

        if DeadBro.configuration.excluded_job?(job_class_name)
          drain_job_tracking
          return
        end
        # If exclusive_jobs is defined and not empty, only track matching jobs
        unless DeadBro.configuration.exclusive_job?(job_class_name)
          drain_job_tracking
          return
        end
      rescue
      end

      has_error = !exception.nil?

      # Skip out via sampling before we build any payload — jobs can be chatty
      # enough that even the "cheap" stop/analyze work matters under load.
      # Errors always ship regardless of sampling, matching Subscriber's web path.
      job_type_key = "#{job_class_name}#perform"
      unless has_error || DeadBro.configuration.should_sample?(job_type_key)
        drain_job_tracking
        return
      end

      duration_ms = ((finished - started) * 1000.0).round(2)
      queue_duration_ms = job_queue_duration_ms(enqueued_at, started)

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
      transaction_events = DeadBro::SqlSubscriber.last_transaction_events
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
        job_class: job_class_name,
        job_id: job_id,
        queue_name: queue_name,
        arguments: safe_arguments(arguments),
        started_at: started.utc.iso8601(3),
        duration_ms: duration_ms,
        queue_duration_ms: queue_duration_ms,
        db_connection_wait_ms: db_connection_stats[:wait_ms],
        db_connection_checkouts: db_connection_stats[:checkouts],
        gc_pressure: gc_pressure,
        ar_instantiation_count: ar_instantiation_count,
        status: has_error ? "failed" : "completed",
        sql_queries: sql_queries,
        transaction_events: transaction_events,
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

      if has_error
        payload[:exception_class] = exception.class.name
        payload[:message] = exception.message.to_s[0, 1000]
        payload[:backtrace] = Array(exception.backtrace).first(50)
        payload[:fingerprint] = DeadBro::Subscriber.compute_error_fingerprint(exception)
        payload[:cause_chain] = DeadBro::Subscriber.build_cause_chain(exception)
        payload[:error] = true
        payload[:error_handling] = error_handling if error_handling
      end

      # force: true — errors always ship, bypassing sampling by design; for
      # completions the sampling decision above already accounted for any
      # per-job-type override, so client#post_metric must not re-roll it globally.
      client.post_metric(event_name: event_name, payload: payload, force: true)
    rescue
      # Never raise into the job
    end

    # Release job-side thread-local tracking state when we've decided not to
    # build a payload (excluded job / sampled out). Matches Subscriber.drain_request_tracking.
    def self.drain_job_tracking
      # wait_for_explains: false — result is discarded, don't block on pending plans.
      # stop_request_tracking also pops the transaction-events stack (see its comment).
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

    # enqueued_at is a Time or an ISO 8601 string from ActiveJob, or an epoch from
    # Sidekiq: float seconds before Sidekiq 8, integer milliseconds since.
    def self.job_queue_duration_ms(enqueued_at, perform_started)
      return nil if enqueued_at.nil?

      enqueued_time = case enqueued_at
      when Time then enqueued_at
      when Numeric then Time.at((enqueued_at > 100_000_000_000) ? enqueued_at / 1000.0 : enqueued_at)
      else Time.parse(enqueued_at.to_s)
      end
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
        # A bare `when ActiveRecord::Base` raises NameError without ActiveRecord
        # loaded, and the rescue below would then drop every argument.
        when ->(a) { defined?(ActiveRecord::Base) && a.is_a?(ActiveRecord::Base) }
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
