# frozen_string_literal: true

require "active_support/notifications"

module DeadBro
  class MemoryTrackingSubscriber
    # Allocation counts come from the process_action event (Rails instruments
    # allocations there via ActiveSupport::Notifications). The old
    # "object_allocations.active_support" constant was never emitted by Rails,
    # so that subscription was dead code — removed.
    PROCESS_ACTION_EVENT = "process_action.action_controller"

    THREAD_LOCAL_KEY = :dead_bro_memory_events
    # Consider objects larger than this many bytes as "large"
    LARGE_OBJECT_THRESHOLD = 1_000_000 # 1MB threshold for large objects

    # Performance optimization settings
    MAX_ALLOCATIONS_PER_REQUEST = 1000 # Limit allocations tracked per request
    LARGE_OBJECT_SAMPLE_RATE = 0.01 # Sample 1% of live objects to estimate large ones
    MAX_LARGE_OBJECTS = 50 # Cap number of large objects captured per request

    def self.subscribe!(client: Client.new)
      # Only enable allocation tracking if explicitly enabled (expensive!)
      return unless DeadBro.configuration.allocation_tracking_enabled
      if defined?(ActiveSupport::Notifications) && ActiveSupport::Notifications.notifier.respond_to?(:subscribe)
        begin
          # Subscribe to process_action to capture request-level allocation counters
          ActiveSupport::Notifications.subscribe(PROCESS_ACTION_EVENT) do |*args|
            event = if args.length == 1 && args.first.is_a?(ActiveSupport::Notifications::Event)
              args.first
            else
              ActiveSupport::Notifications::Event.new(*args)
            end
            allocations = event.respond_to?(:allocations) ? event.allocations : event.payload[:allocations]
            allocated_bytes = event.respond_to?(:allocated_bytes) ? event.allocated_bytes : event.payload[:allocated_bytes]
            next unless allocations || allocated_bytes

            record_request_allocations(
              allocations: allocations,
              allocated_bytes: allocated_bytes
            )
          end
        rescue
          # Allocation tracking might not be available in all Ruby versions
        end
      end
    rescue
      # Never raise from instrumentation install
    end

    # Current frame (top of stack) for nested job tracking; nil if none.
    def self.current_events
      stack = Thread.current[THREAD_LOCAL_KEY]
      return nil unless stack.is_a?(Array) && stack.any?
      stack.last
    end

    def self.start_request_tracking
      # Only track if memory tracking is enabled
      return unless DeadBro.configuration.memory_tracking_enabled

      frame = {
        allocations: [],
        memory_snapshots: [],
        large_objects: [],
        request_allocations: nil,
        gc_before: gc_stats,
        memory_before: memory_usage_mb,
        start_time: Time.now.to_f,
        object_counts_before: count_objects_snapshot
      }
      (Thread.current[THREAD_LOCAL_KEY] ||= []) << frame
    end

    def self.stop_request_tracking
      stack = Thread.current[THREAD_LOCAL_KEY]
      events = (stack.is_a?(Array) && stack.any?) ? stack.pop : nil
      Thread.current[THREAD_LOCAL_KEY] = nil if stack.nil? || stack.empty?

      if events
        events[:gc_after] = gc_stats
        events[:memory_after] = memory_usage_mb
        events[:end_time] = Time.now.to_f
        events[:duration_seconds] = events[:end_time] - events[:start_time]
        events[:object_counts_after] = count_objects_snapshot

        # Fallback large object detection via ObjectSpace sampling
        if (events[:large_objects].nil? || events[:large_objects].empty?) && object_space_available?
          events[:large_objects] = sample_large_objects
        end
      end

      events || {}
    end

    # Record request-level allocation counters from Rails instrumentation.
    def self.record_request_allocations(allocations:, allocated_bytes:)
      events = current_events
      return unless events

      events[:request_allocations] = {
        allocations: allocations,
        allocated_bytes: allocated_bytes
      }
    end

    def self.track_allocation(data, started, finished)
      events = current_events
      return unless events

      # Only track if we have meaningful allocation data
      return unless data.is_a?(Hash) && data[:count] && data[:size]

      # Limit allocations per request to prevent memory bloat
      allocations = events[:allocations]
      return if allocations.length >= MAX_ALLOCATIONS_PER_REQUEST

      # Simplified allocation tracking (avoid expensive operations)
      allocation = {
        class_name: data[:class_name] || "Unknown",
        count: data[:count],
        size: data[:size]
        # Removed expensive fields: duration_ms, timestamp, memory_usage
      }

      # Track large object allocations (these are rare and important)
      if data[:size] > LARGE_OBJECT_THRESHOLD
        large_object = allocation.merge(
          large_object: true,
          size_mb: (data[:size] / 1_000_000.0).round(2)
        )
        events[:large_objects] << large_object
      end

      events[:allocations] << allocation
    end

    def self.take_memory_snapshot(label = nil)
      events = current_events
      return unless events

      snapshot = {
        label: label || "snapshot_#{Time.now.to_i}",
        memory_usage: memory_usage_mb,
        gc_stats: gc_stats,
        timestamp: Time.now.utc.to_i,
        object_count: object_count,
        heap_pages: heap_pages
      }

      events[:memory_snapshots] << snapshot
    end

    def self.analyze_memory_performance(memory_events)
      return {} if memory_events.empty?

      allocations = memory_events[:allocations] || []
      large_objects = memory_events[:large_objects] || []
      snapshots = memory_events[:memory_snapshots] || []
      request_allocations = memory_events[:request_allocations]

      # Calculate memory growth
      memory_growth = 0
      if memory_events[:memory_before] && memory_events[:memory_after]
        memory_growth = memory_events[:memory_after] - memory_events[:memory_before]
      end

      # Calculate allocation totals
      total_allocations = allocations.sum { |a| a[:count] }
      total_allocated_size = allocations.sum { |a| a[:size] }
      if request_allocations
        total_allocated_size = request_allocations[:allocated_bytes].to_i if total_allocated_size.zero?
      end
      gc_allocations = nil
      if memory_events[:gc_before] && memory_events[:gc_after]
        gc_allocations = (memory_events[:gc_after][:total_allocated_objects] || 0) -
          (memory_events[:gc_before][:total_allocated_objects] || 0)
      end
      if gc_allocations.to_i > 0
        total_allocations = gc_allocations
      elsif total_allocations.zero? && request_allocations
        total_allocations = request_allocations[:allocations].to_i
      end

      # Group allocations by class
      allocations_by_class = allocations.group_by { |a| a[:class_name] }
        .transform_values { |allocs|
          {
            count: allocs.sum { |a| a[:count] },
            size: allocs.sum { |a| a[:size] }
          }
      }

      # Find top allocating classes
      top_allocating_classes = allocations_by_class.sort_by { |_, data| -data[:size] }.first(10)

      # Analyze large objects
      large_object_analysis = analyze_large_objects(large_objects)

      # Analyze memory snapshots for trends
      memory_trends = analyze_memory_trends(snapshots)

      # Calculate GC efficiency
      gc_efficiency = calculate_gc_efficiency(memory_events[:gc_before], memory_events[:gc_after])

      # Analyze object type deltas (by Ruby object type, not class)
      object_type_deltas = {}
      if memory_events[:object_counts_before].is_a?(Hash) && memory_events[:object_counts_after].is_a?(Hash)
        before = memory_events[:object_counts_before]
        after = memory_events[:object_counts_after]
        keys = (before.keys + after.keys).uniq
        keys.each do |k|
          object_type_deltas[k] = (after[k] || 0) - (before[k] || 0)
        end
      end

      {
        memory_growth_mb: memory_growth.round(2),
        total_allocations: total_allocations,
        total_allocated_size: total_allocated_size,
        total_allocated_size_mb: (total_allocated_size / 1_000_000.0).round(2),
        allocations_per_second: (memory_events[:duration_seconds] > 0) ?
          (total_allocations.to_f / memory_events[:duration_seconds]).round(2) : 0,
        top_allocating_classes: top_allocating_classes.map { |class_name, data|
          {
            class: class_name,
            name: class_name,
            count: data[:count],
            size: data[:size],
            size_mb: (data[:size] / 1_000_000.0).round(2)
          }
        },
        large_objects: large_object_analysis,
        memory_trends: memory_trends,
        gc_efficiency: gc_efficiency,
        memory_snapshots_count: snapshots.count,
        object_type_deltas: top_object_type_deltas(object_type_deltas, limit: 10)
      }
    end

    def self.analyze_large_objects(large_objects)
      return {} if large_objects.empty?

      {
        count: large_objects.count,
        total_size_mb: large_objects.sum { |obj| obj[:size_mb] }.round(2),
        largest_object_mb: large_objects.max_by { |obj| obj[:size_mb] }[:size_mb],
        by_class: large_objects.group_by { |obj| obj[:class_name] }
          .transform_values(&:count)
      }
    end

    def self.top_object_type_deltas(deltas, limit: 10)
      return {} unless deltas.is_a?(Hash)
      deltas.sort_by { |_, v| -v.abs }.first(limit).to_h
    end

    def self.object_space_available?
      defined?(ObjectSpace) && ObjectSpace.respond_to?(:each_object) && ObjectSpace.respond_to?(:memsize_of)
    end

    def self.sample_large_objects
      results = []
      return results unless object_space_available?

      begin
        # Sample across common heap object types
        ObjectSpace.each_object do |obj|
          # Randomly sample to control overhead
          next unless rand < LARGE_OBJECT_SAMPLE_RATE

          size = begin
            ObjectSpace.memsize_of(obj)
          rescue
            0
          end
          next unless size && size > LARGE_OBJECT_THRESHOLD

          klass = begin
            (obj.respond_to?(:class) && obj.class) ? obj.class.name : "Unknown"
          rescue
            "Unknown"
          end
          results << {class_name: klass, size: size, size_mb: (size / 1_000_000.0).round(2)}

          break if results.length >= MAX_LARGE_OBJECTS
        end
      rescue
        # Best-effort only
      end

      # Sort largest first and keep top N
      results.sort_by { |h| -h[:size] }.first(MAX_LARGE_OBJECTS)
    end

    def self.count_objects_snapshot
      if defined?(ObjectSpace) && ObjectSpace.respond_to?(:count_objects)
        ObjectSpace.count_objects.dup
      else
        {}
      end
    rescue
      {}
    end

    def self.analyze_memory_trends(snapshots)
      return {} if snapshots.length < 2

      # Calculate memory growth rate between snapshots
      memory_values = snapshots.map { |s| s[:memory_usage] }
      memory_growth_rates = []

      (1...memory_values.length).each do |i|
        growth = memory_values[i] - memory_values[i - 1]
        time_diff = snapshots[i][:timestamp] - snapshots[i - 1][:timestamp]
        rate = (time_diff > 0) ? growth / time_diff : 0
        memory_growth_rates << rate
      end

      {
        average_growth_rate_mb_per_second: memory_growth_rates.sum / memory_growth_rates.length,
        max_growth_rate_mb_per_second: memory_growth_rates.max,
        memory_volatility: memory_growth_rates.map(&:abs).sum / memory_growth_rates.length,
        peak_memory_mb: memory_values.max,
        min_memory_mb: memory_values.min
      }
    end

    def self.calculate_gc_efficiency(gc_before, gc_after)
      return {} unless gc_before && gc_after

      {
        gc_count_increase: (gc_after[:count] || 0) - (gc_before[:count] || 0),
        heap_pages_increase: (gc_after[:heap_allocated_pages] || 0) - (gc_before[:heap_allocated_pages] || 0),
        objects_allocated: (gc_after[:total_allocated_objects] || 0) - (gc_before[:total_allocated_objects] || 0),
        gc_frequency: (gc_after[:count] && gc_before[:count]) ?
          (gc_after[:count] - gc_before[:count]).to_f / [gc_after[:count], 1].max : 0
      }
    end

    def self.memory_usage_mb
      # MemoryHelpers.rss_mb reads /proc/self/status on Linux and caches for
      # ~1 second across threads, so this is safe to call per-request.
      DeadBro::MemoryHelpers.rss_mb
    rescue
      0
    end

    def self.gc_stats
      if defined?(GC) && GC.respond_to?(:stat)
        stats = GC.stat
        {
          count: stats[:count] || 0,
          heap_allocated_pages: stats[:heap_allocated_pages] || 0,
          heap_sorted_pages: stats[:heap_sorted_pages] || 0,
          total_allocated_objects: stats[:total_allocated_objects] || 0,
          heap_live_slots: stats[:heap_live_slots] || 0,
          heap_eden_pages: stats[:heap_eden_pages] || 0,
          heap_tomb_pages: stats[:heap_tomb_pages] || 0
        }
      else
        {}
      end
    rescue
      {}
    end

    def self.object_count
      if defined?(GC) && GC.respond_to?(:stat)
        GC.stat[:heap_live_slots] || 0
      else
        0
      end
    rescue
      0
    end

    def self.heap_pages
      if defined?(GC) && GC.respond_to?(:stat)
        GC.stat[:heap_allocated_pages] || 0
      else
        0
      end
    rescue
      0
    end

    # Helper method to take memory snapshots at specific points
    def self.snapshot_at(label)
      take_memory_snapshot(label)
    end
  end
end
