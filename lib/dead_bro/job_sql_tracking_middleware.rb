# frozen_string_literal: true

module DeadBro
  class JobSqlTrackingMiddleware
    def self.subscribe!
      # Start SQL tracking when a job begins - use the start event, not the complete event
      ActiveSupport::Notifications.subscribe("perform_start.active_job") do |name, started, finished, _unique_id, data|
        next if DeadBro.configuration.skip_tracking?

        # Clear logs for this job
        DeadBro.logger.clear

        # Set tracking start time once for all subscribers (before starting any tracking)
        Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now

        DeadBro::SqlSubscriber.start_request_tracking

        # Start dependency tracking so HTTP / Redis / cache / view / Elasticsearch time
        # spent inside the job is captured — mirrors the web SqlTrackingMiddleware. Each
        # of those subscribers only records when its thread-local has been initialized;
        # without this, they silently drop every event during a job and all that time
        # collapses into the "Active Job" residual of the performance breakdown.
        Thread.current[:dead_bro_http_events] = []
        DeadBro::CacheSubscriber.start_request_tracking if defined?(DeadBro::CacheSubscriber)
        DeadBro::RedisSubscriber.start_request_tracking if defined?(DeadBro::RedisSubscriber)
        DeadBro::ElasticsearchSubscriber.start_request_tracking if defined?(DeadBro::ElasticsearchSubscriber)
        DeadBro::ViewRenderingSubscriber.start_request_tracking if defined?(DeadBro::ViewRenderingSubscriber)

        # Start lightweight memory tracking for this job
        if defined?(DeadBro::LightweightMemoryTracker)
          DeadBro::LightweightMemoryTracker.start_request_tracking
        end

        # Start detailed memory tracking when allocation tracking is enabled
        if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
          DeadBro::MemoryTrackingSubscriber.start_request_tracking
        end

        # Start DB connection pool wait tracking
        if defined?(DeadBro::DbConnectionSubscriber)
          DeadBro::DbConnectionSubscriber.start_request_tracking
        end
      end
    rescue
      # Never raise from instrumentation install
    end
  end
end
