# frozen_string_literal: true

module DeadBro
  # Process-wide memory leak detector. Previously stored samples in
  # `Thread.current[...]`, which meant each Puma worker thread saw only the
  # handful of requests it served — far too few samples, and reset whenever a
  # thread was recycled. History is now shared across all threads in the
  # process behind a mutex, with a hard cap on the number of retained samples.
  class MemoryLeakDetector
    LEAK_DETECTION_WINDOW = 300 # seconds (5 minutes)
    MEMORY_GROWTH_THRESHOLD = 50 # MB growth over the window
    MIN_SAMPLES_FOR_LEAK_DETECTION = 10
    MAX_SAMPLES = 500 # hard cap so a long-running process can't grow unbounded
    MAX_LEAK_ALERTS = 10

    @mutex = Mutex.new
    @history = {
      samples: [],
      last_cleanup: Time.now.utc.to_i,
      leak_alerts: []
    }

    class << self
      def record_memory_sample(sample_data)
        sample = {
          timestamp: Time.now.utc.to_i,
          memory_usage: sample_data[:memory_usage] || 0,
          gc_count: sample_data[:gc_count] || 0,
          heap_pages: sample_data[:heap_pages] || 0,
          object_count: sample_data[:object_count] || 0,
          request_id: sample_data[:request_id],
          controller: sample_data[:controller],
          action: sample_data[:action]
        }

        samples_snapshot = @mutex.synchronize do
          @history[:samples] << sample
          cleanup_old_samples_unlocked
          @history[:samples].dup
        end

        check_for_memory_leaks(samples_snapshot)

        nil
      end

      def get_memory_analysis
        samples_snapshot, leak_alerts_snapshot = @mutex.synchronize do
          [@history[:samples].dup, @history[:leak_alerts].dup]
        end

        if samples_snapshot.length < 5
          return {status: "insufficient_data", sample_count: samples_snapshot.length}
        end

        memory_values = samples_snapshot.map { |s| s[:memory_usage] }
        gc_counts = samples_snapshot.map { |s| s[:gc_count] }
        object_counts = samples_snapshot.map { |s| s[:object_count] }

        memory_stats = calculate_stats(memory_values)
        gc_stats = calculate_stats(gc_counts)
        object_stats = calculate_stats(object_counts)
        memory_trend = calculate_memory_trend(memory_values, samples_snapshot.map { |s| s[:timestamp] })

        recent_samples = samples_snapshot.last(10)
        recent_controllers = recent_samples.map { |s| "#{s[:controller]}##{s[:action]}" }.tally

        {
          status: "analyzed",
          sample_count: samples_snapshot.length,
          time_window_seconds: samples_snapshot.last[:timestamp] - samples_snapshot.first[:timestamp],
          memory_stats: memory_stats,
          gc_stats: gc_stats,
          object_stats: object_stats,
          memory_trend: memory_trend,
          recent_controllers: recent_controllers,
          leak_alerts: leak_alerts_snapshot.last(5),
          memory_efficiency: calculate_memory_efficiency(samples_snapshot)
        }
      end

      def clear_history
        @mutex.synchronize do
          @history = {
            samples: [],
            last_cleanup: Time.now.utc.to_i,
            leak_alerts: []
          }
        end
      end

      # Kept for backwards compatibility — history is now initialized at
      # class-load time, so Railtie callers don't need to do anything.
      def initialize_history
        # no-op
      end

      def calculate_memory_trend(memory_values, timestamps)
        return {slope: 0, r_squared: 0} if memory_values.length < 2

        n = memory_values.length
        sum_x = timestamps.sum
        sum_y = memory_values.sum
        sum_xy = timestamps.zip(memory_values).sum { |x, y| x * y }
        sum_x2 = timestamps.sum { |x| x * x }

        denominator = (n * sum_x2 - sum_x * sum_x)
        return {slope: 0, r_squared: 0} if denominator.zero?

        slope = (n * sum_xy - sum_x * sum_y).to_f / denominator
        intercept = (sum_y - slope * sum_x).to_f / n

        y_mean = sum_y.to_f / n
        ss_tot = memory_values.sum { |y| (y - y_mean)**2 }
        ss_res = memory_values.zip(timestamps).sum { |y, x| (y - (slope * x + intercept))**2 }
        r_squared = (ss_tot > 0) ? 1 - (ss_res / ss_tot) : 0

        {slope: slope, intercept: intercept, r_squared: r_squared}
      end

      def calculate_stats(values)
        return {} if values.empty?

        {
          min: values.min,
          max: values.max,
          mean: (values.sum.to_f / values.length).round(2),
          median: values.sort[values.length / 2],
          std_dev: calculate_standard_deviation(values)
        }
      end

      def calculate_standard_deviation(values)
        return 0 if values.length < 2

        mean = values.sum.to_f / values.length
        variance = values.sum { |v| (v - mean)**2 } / (values.length - 1)
        Math.sqrt(variance).round(2)
      end

      def calculate_memory_efficiency(samples)
        return {} if samples.length < 2

        memory_per_object = samples.map do |sample|
          (sample[:object_count] > 0) ? sample[:memory_usage] / sample[:object_count] : 0
        end

        gc_efficiency = []
        (1...samples.length).each do |i|
          gc_delta = samples[i][:gc_count] - samples[i - 1][:gc_count]
          memory_delta = samples[i][:memory_usage] - samples[i - 1][:memory_usage]

          if gc_delta > 0 && memory_delta < 0
            gc_efficiency << (-memory_delta / gc_delta).round(2)
          end
        end

        {
          average_memory_per_object_kb: (memory_per_object.sum / memory_per_object.length).round(2),
          gc_efficiency_mb_per_cycle: gc_efficiency.any? ? (gc_efficiency.sum / gc_efficiency.length).round(2) : 0,
          memory_volatility: calculate_standard_deviation(samples.map { |s| s[:memory_usage] })
        }
      end

      private

      def cleanup_old_samples_unlocked
        cutoff_time = Time.now.utc.to_i - LEAK_DETECTION_WINDOW
        samples = @history[:samples]

        # Drop stale samples by time window.
        if samples.any? && samples.first[:timestamp] <= cutoff_time
          @history[:samples] = samples.select { |s| s[:timestamp] > cutoff_time }
          samples = @history[:samples]
        end

        # Enforce hard cap so a burst of traffic can't grow the buffer forever.
        if samples.length > MAX_SAMPLES
          @history[:samples] = samples.last(MAX_SAMPLES)
        end

        @history[:last_cleanup] = Time.now.utc.to_i
      end

      # Runs the O(N) regression on a pre-copied snapshot so the mutex is not
      # held during the computation. The alert is appended inside a short lock.
      def check_for_memory_leaks(samples)
        return if samples.length < MIN_SAMPLES_FOR_LEAK_DETECTION

        memory_values = samples.map { |s| s[:memory_usage] }
        timestamps    = samples.map { |s| s[:timestamp] }

        trend = calculate_memory_trend(memory_values, timestamps)
        return unless trend[:slope] > 0.1 && trend[:r_squared] > 0.7

        memory_growth = memory_values.last - memory_values.first
        return unless memory_growth > MEMORY_GROWTH_THRESHOLD

        leak_alert = {
          detected_at: Time.now.utc.to_i,
          memory_growth_mb: memory_growth.round(2),
          growth_rate_mb_per_second: trend[:slope],
          confidence: trend[:r_squared],
          sample_count: samples.length,
          time_window_seconds: timestamps.last - timestamps.first,
          recent_controllers: samples.last(5).map { |s| "#{s[:controller]}##{s[:action]}" }.uniq
        }

        @mutex.synchronize do
          @history[:leak_alerts] << leak_alert
          @history[:leak_alerts] = @history[:leak_alerts].last(MAX_LEAK_ALERTS)
        end
      end
    end
  end
end
