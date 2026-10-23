# frozen_string_literal: true

module DeadBro
  # What DeadBro itself costs the request or job it tracks: how long its own
  # code runs on that thread and how many objects it allocates there. Each
  # piece of DeadBro code on the thread — SqlTrackingMiddleware's setup, the
  # notification listeners, the hooks around HTTP and Redis calls, and the
  # listener that builds the sample — runs inside a window on the thread's
  # meter, and the sample carries what the windows add up to when it is handed
  # to the client (agent_overhead_ms, agent_allocated_objects).
  #
  # Not counted: what runs after the reading — Client#post_metric's work on
  # the payload (truncating it, JSON-encoding it, setting up the HTTP request)
  # and the middleware's teardown; ActiveSupport::Notifications' own work to
  # call the listeners; the connection-pool checkout timer (two clock reads);
  # and DeadBro.watch's bookkeeping around the app's block.
  #
  # A GC pause that starts inside a window is left out of its time; the
  # objects DeadBro allocates are counted instead. They are read from the
  # process-wide counter, so another thread's objects are counted too when it
  # runs while DeadBro code waits on I/O (e.g. for a pending EXPLAIN).
  module OverheadTracker
    THREAD_KEY = :dead_bro_overhead

    class Meter
      GC_TIME_AVAILABLE = GC.respond_to?(:total_time)

      # The meter this one interrupted: a job performed inline (perform_now)
      # inside a request or another job is measured on its own, and the outer
      # meter resumes when it ends.
      attr_reader :outer

      def initialize(outer = nil)
        @outer = outer
        @nanoseconds = 0
        @allocations = 0
        @opened_at = nil
        @opened_allocations = 0
        @opened_gc_time = 0
      end

      # Nil when a window is already open: that one counts this code too.
      def open
        return if @opened_at

        @opened_allocations = GC.stat(:total_allocated_objects)
        @opened_gc_time = gc_time
        @opened_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        self
      end

      def close
        @nanoseconds += window_nanoseconds
        @allocations += GC.stat(:total_allocated_objects) - @opened_allocations
        @opened_at = nil
      end

      # The totals so far, the caller's open window included.
      def stamp(payload)
        nanoseconds = @nanoseconds
        allocations = @allocations
        if @opened_at
          nanoseconds += window_nanoseconds
          allocations += GC.stat(:total_allocated_objects) - @opened_allocations
        end
        payload[:agent_overhead_ms] = (nanoseconds / 1_000_000.0).round(3)
        payload[:agent_allocated_objects] = allocations
      end

      private

      def window_nanoseconds
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - @opened_at - (gc_time - @opened_gc_time)
      end

      def gc_time
        GC_TIME_AVAILABLE ? GC.total_time : 0
      end
    end

    def self.start_request_tracking
      Thread.current[THREAD_KEY] = Meter.new(Thread.current[THREAD_KEY])
    end

    def self.stop_request_tracking
      meter = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = meter&.outer
    end

    # Opens a window on this thread's meter. Returns nil when nothing is being
    # measured or a window is already open; hand the result to leave either way.
    def self.enter
      Thread.current[THREAD_KEY]&.open
    end

    def self.leave(meter)
      meter&.close
    end

    # Adds agent_overhead_ms and agent_allocated_objects to a sample's
    # payload. Called last before the payload goes to the client.
    def self.stamp(payload)
      Thread.current[THREAD_KEY]&.stamp(payload)
      payload
    end

    # ActiveSupport::Notifications.subscribe for DeadBro's own listeners: the
    # listener runs inside a window.
    def self.subscribe(pattern, &listener)
      ActiveSupport::Notifications.subscribe(pattern) do |name, started, finished, unique_id, payload|
        overhead = enter
        listener.call(name, started, finished, unique_id, payload)
      ensure
        leave(overhead)
      end
    end
  end
end
