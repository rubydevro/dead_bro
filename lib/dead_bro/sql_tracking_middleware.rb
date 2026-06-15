# frozen_string_literal: true

module DeadBro
  class SqlTrackingMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if DeadBro.configuration.skip_tracking?

      # Capture rack entry time before any setup so middleware overhead is accurately measured.
      rack_entry = Time.now
      Thread.current[DeadBro::TRACKING_START_TIME_KEY] = rack_entry

      # Queue time: gap between when the upstream proxy accepted the connection and when a Rack
      # worker picked it up. Heroku sets X-Request-Start as "t=<microseconds>"; nginx typically
      # uses "t=<seconds.ms>". Both are parsed below.
      Thread.current[:dead_bro_queue_duration_ms] = parse_queue_start(env, rack_entry)

      # Clear logs for this request
      DeadBro.logger.clear

      # Start SQL tracking for this request
      if defined?(DeadBro::SqlSubscriber)
        DeadBro::SqlSubscriber.start_request_tracking
      end

      # Start cache tracking for this request
      if defined?(DeadBro::CacheSubscriber)
        DeadBro::CacheSubscriber.start_request_tracking
      end

      # Start Redis tracking for this request
      if defined?(DeadBro::RedisSubscriber)
        DeadBro::RedisSubscriber.start_request_tracking
      end

      # Start view rendering tracking for this request
      if defined?(DeadBro::ViewRenderingSubscriber)
        DeadBro::ViewRenderingSubscriber.start_request_tracking
      end

      # Start lightweight memory tracking for this request
      if defined?(DeadBro::LightweightMemoryTracker)
        DeadBro::LightweightMemoryTracker.start_request_tracking
      end

      # Decide once whether this request pays for heavy allocation tracking
      # (flag + per-request sampling). Cache the decision so the matching stop
      # in Subscriber agrees with this start.
      alloc_active = DeadBro.configuration.allocation_tracking_active?
      Thread.current[:dead_bro_alloc_active] = alloc_active

      # Start detailed memory + allocation-source tracking when active
      if alloc_active
        DeadBro::MemoryTrackingSubscriber.start_request_tracking if defined?(DeadBro::MemoryTrackingSubscriber)
        DeadBro::AllocationSourceSampler.start if defined?(DeadBro::AllocationSourceSampler)
      end

      # Start Elasticsearch tracking for this request
      if defined?(DeadBro::ElasticsearchSubscriber)
        DeadBro::ElasticsearchSubscriber.start_request_tracking
      end

      # Start DB connection pool wait tracking
      if defined?(DeadBro::DbConnectionSubscriber)
        DeadBro::DbConnectionSubscriber.start_request_tracking
      end

      # Start GC pressure tracking — snapshot before any app code runs
      DeadBro::GcTracker.start_request_tracking if defined?(DeadBro::GcTracker)

      # Start per-phase allocation attribution (~0.1ms; under memory tracking)
      if DeadBro.configuration.memory_tracking_enabled && defined?(DeadBro::MemoryPhaseTracker)
        DeadBro::MemoryPhaseTracker.start_request_tracking
      end

      # Start AR object instantiation counting for this request
      DeadBro::ArObjectTracker.start_request_tracking if defined?(DeadBro::ArObjectTracker)

      # Start CPU time tracking for this request (thread-local clock)
      DeadBro::CpuTracker.start_request_tracking if defined?(DeadBro::CpuTracker)

      # Start outgoing HTTP accumulation for this request
      Thread.current[:dead_bro_http_events] = []

      @app.call(env)
    ensure
      # Clean up thread-local storage
      if defined?(DeadBro::SqlSubscriber)
        Thread.current[:dead_bro_sql_queries]
        Thread.current[:dead_bro_sql_queries] = nil
      end

      if defined?(DeadBro::CacheSubscriber)
        Thread.current[:dead_bro_cache_events]
        Thread.current[:dead_bro_cache_events] = nil
      end

      if defined?(DeadBro::RedisSubscriber)
        Thread.current[:dead_bro_redis_events]
        Thread.current[:dead_bro_redis_events] = nil
      end

      if defined?(DeadBro::ViewRenderingSubscriber)
        Thread.current[:dead_bro_view_events]
        Thread.current[:dead_bro_view_events] = nil
      end

      if defined?(DeadBro::LightweightMemoryTracker)
        Thread.current[:dead_bro_lightweight_memory]
        Thread.current[:dead_bro_lightweight_memory] = nil
      end

      # Clean up HTTP events, ES events, DB connection tracking, and tracking start time
      Thread.current[:dead_bro_elasticsearch_events] = nil
      Thread.current[:dead_bro_http_events] = nil
      Thread.current[:dead_bro_queue_duration_ms] = nil
      DeadBro::DbConnectionSubscriber.stop_request_tracking if defined?(DeadBro::DbConnectionSubscriber)
      Thread.current[DeadBro::GcTracker::THREAD_KEY] = nil if defined?(DeadBro::GcTracker)
      # Bypass stop_request_tracking intentionally — cleanup only, no return value needed here.
      Thread.current[DeadBro::ArObjectTracker::THREAD_KEY] = nil if defined?(DeadBro::ArObjectTracker)
      Thread.current[DeadBro::CpuTracker::THREAD_KEY] = nil if defined?(DeadBro::CpuTracker)
      Thread.current[DeadBro::MemoryPhaseTracker::THREAD_KEY] = nil if defined?(DeadBro::MemoryPhaseTracker)
      # Safety net: ensure allocation tracing is never left running across
      # requests (Subscriber normally stops it after analyzing).
      if Thread.current[:dead_bro_alloc_active]
        DeadBro::AllocationSourceSampler.stop if defined?(DeadBro::AllocationSourceSampler)
      end
      Thread.current[:dead_bro_alloc_active] = nil
      Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
    end

    private

    def parse_queue_start(env, rack_entry)
      raw = env["HTTP_X_REQUEST_START"] || env["HTTP_X_QUEUE_START"]
      return nil if raw.nil? || raw.empty?

      # Strip "t=" prefix used by Heroku and nginx
      raw = raw.sub(/\At=/, "")
      num = raw.to_f
      return nil if num <= 0

      request_start =
        if num > 1_000_000_000_000_000 # microseconds (Heroku)
          Time.at(num / 1_000_000.0)
        elsif num > 1_000_000_000_000 # milliseconds
          Time.at(num / 1_000.0)
        else # seconds (nginx)
          Time.at(num)
        end

      # Guard against clocks being out of sync or wildly misconfigured proxy timestamps.
      # Cap at 60 s — anything larger almost certainly means the header value is wrong.
      diff_ms = ((rack_entry - request_start) * 1000.0).round(2)
      diff_ms >= 0 && diff_ms <= 60_000 ? diff_ms : nil
    rescue
      nil
    end
  end
end
