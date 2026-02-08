# frozen_string_literal: true

module DeadBro
  class LightweightMemoryTracker
    # Ultra-lightweight memory tracking with minimal performance impact
    THREAD_LOCAL_KEY = :dead_bro_lightweight_memory

    def self.start_request_tracking
      return unless DeadBro.configuration.memory_tracking_enabled

      # Stack allows nested job tracking (e.g. one job performing others in the same thread)
      mem_before = lightweight_memory_usage
      frame = {
        gc_before: lightweight_gc_stats,
        memory_before: mem_before,
        start_time: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      }
      (Thread.current[THREAD_LOCAL_KEY] ||= []) << frame
    end

    def self.stop_request_tracking
      stack = Thread.current[THREAD_LOCAL_KEY]
      unless stack.is_a?(Array) && stack.any?
        Thread.current[THREAD_LOCAL_KEY] = nil
        return {}
      end

      events = stack.pop
      Thread.current[THREAD_LOCAL_KEY] = nil if stack.empty?

      # Calculate only essential metrics
      gc_after = lightweight_gc_stats
      memory_after = lightweight_memory_usage

      {
        memory_growth_mb: (memory_after - events[:memory_before]).round(2),
        gc_count_increase: (gc_after[:count] || 0) - (events[:gc_before][:count] || 0),
        heap_pages_increase: (gc_after[:heap_allocated_pages] || 0) - (events[:gc_before][:heap_allocated_pages] || 0),
        duration_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - events[:start_time],
        memory_before: events[:memory_before],
        memory_after: memory_after
      }
    end

    def self.lightweight_memory_usage
      # Use only GC stats for memory estimation (no system calls)
      return 0 unless defined?(GC) && GC.respond_to?(:stat)

      gc_stats = GC.stat
      heap_pages = gc_stats[:heap_allocated_pages] || 0
      # Rough estimation: 4KB per page
      (heap_pages * 4) / 1024.0 # Convert to MB
    rescue
      0
    end

    def self.lightweight_gc_stats
      return {} unless defined?(GC) && GC.respond_to?(:stat)

      stats = GC.stat
      {
        count: stats[:count] || 0,
        heap_allocated_pages: stats[:heap_allocated_pages] || 0
      }
    rescue
      {}
    end
  end
end
