# frozen_string_literal: true

require "active_support/notifications"

module DeadBro
  module ArObjectTracker
    THREAD_KEY = :dead_bro_ar_objects

    def self.subscribe!
      return if @subscribed
      @subscribed = true
      ActiveSupport::Notifications.subscribe("instantiation.active_record") do |_name, _started, _finished, _id, data|
        count = Thread.current[THREAD_KEY]
        next unless count
        Thread.current[THREAD_KEY] = count + (data[:record_count] || 1).to_i
      end
    rescue StandardError
      # Never raise from instrumentation install
    end

    def self.start_request_tracking
      Thread.current[THREAD_KEY] = 0
    end

    def self.stop_request_tracking
      Thread.current[THREAD_KEY]
    ensure
      Thread.current[THREAD_KEY] = nil
    end
  end
end
