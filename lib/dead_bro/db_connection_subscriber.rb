# frozen_string_literal: true

module DeadBro
  module DbConnectionSubscriber
    WAIT_KEY  = :dead_bro_db_connection_wait_ms
    COUNT_KEY = :dead_bro_db_connection_checkouts

    # Prepended onto ConnectionPool so every checkout is timed.
    # Only accumulates when a request is being tracked (thread-local is a Numeric).
    module CheckoutInstrumentation
      def checkout(*args)
        return super unless Thread.current[DbConnectionSubscriber::WAIT_KEY].is_a?(Numeric)

        # Initialize conn before calling super so the rescue block can tell whether
        # checkout succeeded before timing code raised (avoids double-checkout).
        conn = nil
        t0   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        conn = super
        Thread.current[DbConnectionSubscriber::WAIT_KEY]  += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
        Thread.current[DbConnectionSubscriber::COUNT_KEY] += 1
        conn
      rescue
        conn || super
      end
    end

    def self.install!
      return unless defined?(ActiveRecord::ConnectionAdapters::ConnectionPool)
      return if ActiveRecord::ConnectionAdapters::ConnectionPool.ancestors.include?(CheckoutInstrumentation)

      ActiveRecord::ConnectionAdapters::ConnectionPool.prepend(CheckoutInstrumentation)
    rescue StandardError => e
      warn "[DeadBro] DbConnectionSubscriber install failed: #{e.class}: #{e.message}"
    end

    def self.start_request_tracking
      Thread.current[WAIT_KEY]  = 0.0
      Thread.current[COUNT_KEY] = 0
    end

    def self.stop_request_tracking
      wait_ms   = Thread.current[WAIT_KEY]
      checkouts = Thread.current[COUNT_KEY]
      Thread.current[WAIT_KEY]  = nil
      Thread.current[COUNT_KEY] = nil
      { wait_ms: wait_ms&.round(2), checkouts: checkouts }
    end
  end
end
