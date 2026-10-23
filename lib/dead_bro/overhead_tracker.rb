# frozen_string_literal: true

module DeadBro
  # What DeadBro itself costs the request or job it tracks: the CPU time its
  # own code uses on that thread and how many objects it allocates there. Each
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
  # Time is the thread's CPU time, so a garbage collection that runs on the
  # thread inside a window counts, and time the thread spends off the CPU —
  # waiting on I/O, or for the GVL while another thread runs — doesn't.
  # Allocations come from the process-wide counter, which also counts other
  # threads' objects: a window in which the thread was off the CPU for longer
  # than clock noise explains (another thread ran meanwhile) adds its time but
  # not its objects. DeadBro code that gives up the GVL — the /proc read for
  # RSS, the wait for pending EXPLAINs — runs as a window of its own
  # (isolate), so only that stretch's objects are left out.
  module OverheadTracker
    THREAD_KEY = :dead_bro_overhead

    class Meter
      # The thread's CPU clock where the platform has one. Without it, windows
      # are timed by the wall clock and can't tell that another thread ran.
      CPU_CLOCK = begin
        Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
        Process::CLOCK_THREAD_CPUTIME_ID
      rescue NameError, SystemCallError
        Process::CLOCK_MONOTONIC
      end

      # How much longer than its CPU time a window may take on the wall clock
      # before it counts as having been off the CPU: this much, plus a quarter
      # of its CPU time, for noise that grows with the window (e.g. a virtual
      # machine's steal time).
      OFF_CPU_TOLERANCE_NS = 20_000

      # The meter this one interrupted: a job performed inline (perform_now)
      # inside a request or another job is measured on its own, and the outer
      # meter resumes when it ends.
      attr_reader :outer

      def initialize(outer = nil)
        @outer = outer
        @cpu_nanoseconds = 0
        @allocations = 0
        @opened_at = nil
        @opened_cpu = 0
        @opened_allocations = 0
      end

      def open?
        !@opened_at.nil?
      end

      # Nil when a window is already open: that one counts this code too.
      #
      # The clocks are read outside the allocation counter (here and in
      # close), so whatever takes the thread off the CPU between the two
      # counter reads also shows in the wall-clock time.
      def open
        return if @opened_at

        @opened_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        @opened_cpu = Process.clock_gettime(CPU_CLOCK, :nanosecond)
        @opened_allocations = GC.stat(:total_allocated_objects)
        self
      end

      def close
        allocations = GC.stat(:total_allocated_objects) - @opened_allocations
        cpu = Process.clock_gettime(CPU_CLOCK, :nanosecond) - @opened_cpu
        off_cpu = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - @opened_at - cpu

        @cpu_nanoseconds += cpu
        @allocations += allocations if off_cpu <= OFF_CPU_TOLERANCE_NS + (cpu >> 2)
        @opened_at = nil
      end

      # The totals so far, the caller's open window included: it is closed
      # here and the rest of it goes on as a new window.
      def stamp(payload)
        if @opened_at
          close
          open
        end
        payload[:agent_overhead_ms] = (@cpu_nanoseconds / 1_000_000.0).round(3)
        payload[:agent_allocated_objects] = @allocations
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

    # Runs DeadBro code that can give up the GVL (reading /proc, waiting for
    # another thread) as a window of its own inside the open one, so that a
    # thread that runs meanwhile costs this stretch its object count, not the
    # whole window around it. Just runs the block when no window is open.
    def self.isolate
      meter = Thread.current[THREAD_KEY]
      return yield unless meter&.open?

      begin
        meter.close
        meter.open
        yield
      ensure
        meter.close
        meter.open
      end
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
