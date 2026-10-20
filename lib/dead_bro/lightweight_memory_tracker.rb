# frozen_string_literal: true

module DeadBro
  class LightweightMemoryTracker
    # Ultra-lightweight memory tracking with minimal performance impact
    THREAD_LOCAL_KEY = :dead_bro_lightweight_memory

    def self.start_request_tracking
      return unless DeadBro.configuration.memory_tracking_enabled

      # Stack allows nested job tracking (e.g. one job performing others in the same thread)
      frame = {
        gc_count_before: gc_count,
        heap_pages_before: heap_allocated_pages,
        memory_before: lightweight_memory_usage,
        start_time: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      }
      (Thread.current[THREAD_LOCAL_KEY] ||= []) << frame
    end

    def self.stop_request_tracking
      frame = take_frame
      return {} unless frame

      result(frame,
        memory_after: lightweight_memory_usage,
        gc_count_after: gc_count,
        heap_pages_after: heap_allocated_pages,
        finished_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end

    # Pops this level's frame without reading anything else, for a caller that
    # takes its own end-of-request readings and calls .result off the request
    # thread. nil when tracking wasn't started. The (empty) stack stays on the
    # thread for its next request.
    def self.take_frame
      stack = Thread.current[THREAD_LOCAL_KEY]
      return nil unless stack.is_a?(Array) && !stack.empty?

      stack.pop
    end

    # The memory metrics for a frame, given the end readings: RSS in MB, GC
    # count, allocated heap pages and a monotonic time.
    def self.result(frame, memory_after:, gc_count_after:, heap_pages_after:, finished_at:)
      return {} unless frame

      {
        memory_growth_mb: (memory_after - frame[:memory_before]).round(2),
        gc_count_increase: gc_count_after - (frame[:gc_count_before] || 0),
        heap_pages_increase: heap_pages_after - (frame[:heap_pages_before] || 0),
        duration_seconds: finished_at - frame[:start_time],
        memory_before: frame[:memory_before],
        memory_after: memory_after
      }
    end

    def self.lightweight_memory_usage
      # Real RSS, cached for ~1s across threads so this is cheap even on hot
      # paths. Previous versions multiplied heap_pages by 4KB and labelled the
      # result as MB — both the unit and the page size were wrong (MRI heap
      # pages are ~16KB and heap != RSS), so the number was effectively fiction.
      DeadBro::MemoryHelpers.rss_mb
    rescue
      0
    end

    # Single-key GC.stat reads: an Integer each, no Hash built.
    def self.gc_count
      GC.stat(:count)
    rescue
      0
    end

    def self.heap_allocated_pages
      GC.stat(:heap_allocated_pages)
    rescue
      0
    end
  end
end
