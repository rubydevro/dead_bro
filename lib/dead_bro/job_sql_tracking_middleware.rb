# frozen_string_literal: true

module DeadBro
  class JobSqlTrackingMiddleware
    def self.subscribe!
      # Start SQL tracking when a job begins - use the start event, not the complete event
      ActiveSupport::Notifications.subscribe("perform_start.active_job") do |name, started, finished, _unique_id, data|
        # Clear logs for this job
        DeadBro.logger.clear
        DeadBro::SqlSubscriber.start_request_tracking

        # Start lightweight memory tracking for this job
        if defined?(DeadBro::LightweightMemoryTracker)
          DeadBro::LightweightMemoryTracker.start_request_tracking
        end

        # Start detailed memory tracking when allocation tracking is enabled
        if DeadBro.configuration.allocation_tracking_enabled && defined?(DeadBro::MemoryTrackingSubscriber)
          DeadBro::MemoryTrackingSubscriber.start_request_tracking
        end
      end
    rescue
      # Never raise from instrumentation install
    end
  end
end
