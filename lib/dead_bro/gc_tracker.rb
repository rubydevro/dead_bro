# frozen_string_literal: true

module DeadBro
  module GcTracker
    THREAD_KEY = :dead_bro_gc_start

    def self.start_request_tracking
      Thread.current[THREAD_KEY] = snapshot
    end

    def self.stop_request_tracking
      before = Thread.current[THREAD_KEY]
      return {} if before.nil? || before.empty?
      diff(before, snapshot)
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    def self.snapshot
      return {} unless defined?(GC) && GC.respond_to?(:stat)
      stat = GC.stat
      base = {
        minor_gc_count: stat[:minor_gc_count] || 0,
        major_gc_count: stat[:major_gc_count] || 0,
        total_allocated_objects: stat[:total_allocated_objects] || 0,
        gc_time_ns: GC.respond_to?(:total_time) ? GC.total_time : nil
      }

      # Memory-tracking enrichment (a few extra GC.stat reads). Only the base
      # GC pressure fields above are truly always-on.
      if memory_tracking_enabled?
        # Live heap slots — net retained objects. Comparing this delta against
        # allocated_objects separates transient churn from genuine retention.
        base[:heap_live_slots] = stat[:heap_live_slots] || 0
        # Bytes malloc'd outside the Ruby object heap (big strings/buffers, e.g.
        # parsed JSON response bodies). These are point-in-time gauges reset by
        # GC, so we report the request-end value rather than a diff.
        base[:malloc_increase_bytes] = stat[:malloc_increase_bytes] || 0
        base[:oldmalloc_increase_bytes] = stat[:oldmalloc_increase_bytes] || 0
      end

      base
    rescue
      {}
    end

    def self.diff(before, after)
      return {} if before.empty? || after.empty?
      gc_time_ms = if before[:gc_time_ns] && after[:gc_time_ns]
        ((after[:gc_time_ns] - before[:gc_time_ns]) / 1_000_000.0).round(3)
      end
      result = {
        minor_gc_runs: (after[:minor_gc_count] || 0) - (before[:minor_gc_count] || 0),
        major_gc_runs: (after[:major_gc_count] || 0) - (before[:major_gc_count] || 0),
        allocated_objects: (after[:total_allocated_objects] || 0) - (before[:total_allocated_objects] || 0),
        gc_time_ms: gc_time_ms
      }

      # Present only when the enrichment was captured (memory tracking enabled).
      if after.key?(:heap_live_slots) || before.key?(:heap_live_slots)
        # Net change in live slots over the request. A small value alongside a
        # large allocated_objects means the memory was transient (reclaimed by
        # GC); a large value means objects were retained — the real leak signal.
        result[:heap_live_slots_growth] = (after[:heap_live_slots] || 0) - (before[:heap_live_slots] || 0)
        # Off-heap malloc pressure pending at request end (see snapshot).
        result[:malloc_increase_bytes] = after[:malloc_increase_bytes] || 0
        result[:oldmalloc_increase_bytes] = after[:oldmalloc_increase_bytes] || 0
      end

      result
    rescue
      {}
    end

    def self.memory_tracking_enabled?
      DeadBro.configuration.memory_tracking_enabled
    rescue
      false
    end
  end
end
