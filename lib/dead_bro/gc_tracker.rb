# frozen_string_literal: true

module DeadBro
  module GcTracker
    THREAD_KEY = :dead_bro_gc_start

    def self.start_request_tracking
      Thread.current[THREAD_KEY] = snapshot
    end

    def self.stop_request_tracking
      before = Thread.current[THREAD_KEY]
      return {} unless before&.any?
      diff(before, snapshot)
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    def self.snapshot
      return {} unless defined?(GC) && GC.respond_to?(:stat)
      stat = GC.stat
      {
        minor_gc_count: stat[:minor_gc_count] || 0,
        major_gc_count: stat[:major_gc_count] || 0,
        total_allocated_objects: stat[:total_allocated_objects] || 0,
        heap_live_slots: stat[:heap_live_slots] || 0,
        gc_time_ns: GC.respond_to?(:total_time) ? GC.total_time : nil
      }
    rescue
      {}
    end

    def self.diff(before, after)
      return {} if before.empty? || after.empty?
      gc_time_ms = if before[:gc_time_ns] && after[:gc_time_ns]
        ((after[:gc_time_ns] - before[:gc_time_ns]) / 1_000_000.0).round(3)
      end
      {
        minor_gc_runs: (after[:minor_gc_count] || 0) - (before[:minor_gc_count] || 0),
        major_gc_runs: (after[:major_gc_count] || 0) - (before[:major_gc_count] || 0),
        allocated_objects: (after[:total_allocated_objects] || 0) - (before[:total_allocated_objects] || 0),
        heap_live_slots_delta: (after[:heap_live_slots] || 0) - (before[:heap_live_slots] || 0),
        gc_time_ms: gc_time_ms
      }
    rescue
      {}
    end
  end
end
