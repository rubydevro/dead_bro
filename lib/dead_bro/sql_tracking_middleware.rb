# frozen_string_literal: true

module DeadBro
  class SqlTrackingMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
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

      # Start detailed memory tracking when allocation tracking is enabled
      if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
        DeadBro::MemoryTrackingSubscriber.start_request_tracking
      end

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

      # Clean up HTTP events
      Thread.current[:dead_bro_http_events] = nil
    end
  end
end
