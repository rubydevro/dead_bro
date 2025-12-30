# frozen_string_literal: true

module DeadBro
  class MemoryLeakDetector
    # Track memory patterns over time to detect leaks
    MEMORY_HISTORY_KEY = :dead_bro_memory_history
    LEAK_DETECTION_WINDOW = 300 # 5 minutes
    MEMORY_GROWTH_THRESHOLD = 50 # 50MB growth threshold
    MIN_SAMPLES_FOR_LEAK_DETECTION = 10

    def self.initialize_history
      Thread.current[MEMORY_HISTORY_KEY] = {
        samples: [],
        last_cleanup: Time.now.utc.to_i,
        leak_alerts: []
      }
    end

    def self.record_memory_sample(sample_data)
      history = Thread.current[MEMORY_HISTORY_KEY] || initialize_history

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

      history[:samples] << sample

      # Clean up old samples
      cleanup_old_samples(history)

      # Check for memory leaks
      check_for_memory_leaks(history)

      history
    end

    def self.cleanup_old_samples(history)
      cutoff_time = Time.now.utc.to_i - LEAK_DETECTION_WINDOW
      history[:samples] = history[:samples].select { |sample| sample[:timestamp] > cutoff_time }
    end

    def self.check_for_memory_leaks(history)
      samples = history[:samples]
      return if samples.length < MIN_SAMPLES_FOR_LEAK_DETECTION

      # Calculate memory growth trend
      memory_values = samples.map { |s| s[:memory_usage] }
      timestamps = samples.map { |s| s[:timestamp] }

      # Use linear regression to detect upward trend
      trend = calculate_memory_trend(memory_values, timestamps)

      # Check if memory is growing consistently
      if trend[:slope] > 0.1 && trend[:r_squared] > 0.7 # Growing with good correlation
        memory_growth = memory_values.last - memory_values.first

        if memory_growth > MEMORY_GROWTH_THRESHOLD
          leak_alert = {
            detected_at: Time.now.utc.to_i,
            memory_growth_mb: memory_growth.round(2),
            growth_rate_mb_per_second: trend[:slope],
            confidence: trend[:r_squared],
            sample_count: samples.length,
            time_window_seconds: timestamps.last - timestamps.first,
            recent_controllers: samples.last(5).map { |s| "#{s[:controller]}##{s[:action]}" }.uniq
          }

          history[:leak_alerts] << leak_alert

          # Only keep recent leak alerts
          history[:leak_alerts] = history[:leak_alerts].last(10)
        end
      end
    end

    def self.calculate_memory_trend(memory_values, timestamps)
      return {slope: 0, r_squared: 0} if memory_values.length < 2

      n = memory_values.length
      sum_x = timestamps.sum
      sum_y = memory_values.sum
      sum_xy = timestamps.zip(memory_values).sum { |x, y| x * y }
      sum_x2 = timestamps.sum { |x| x * x }
      memory_values.sum { |y| y * y }

      # Calculate slope (m) and intercept (b) for y = mx + b
      slope = (n * sum_xy - sum_x * sum_y).to_f / (n * sum_x2 - sum_x * sum_x)
      intercept = (sum_y - slope * sum_x).to_f / n

      # Calculate R-squared (coefficient of determination)
      y_mean = sum_y.to_f / n
      ss_tot = memory_values.sum { |y| (y - y_mean)**2 }
      ss_res = memory_values.zip(timestamps).sum { |y, x| (y - (slope * x + intercept))**2 }
      r_squared = (ss_tot > 0) ? 1 - (ss_res / ss_tot) : 0

      {
        slope: slope,
        intercept: intercept,
        r_squared: r_squared
      }
    end

    def self.get_memory_analysis
      history = Thread.current[MEMORY_HISTORY_KEY] || initialize_history
      samples = history[:samples]

      return {status: "insufficient_data", sample_count: samples.length} if samples.length < 5

      memory_values = samples.map { |s| s[:memory_usage] }
      gc_counts = samples.map { |s| s[:gc_count] }
      object_counts = samples.map { |s| s[:object_count] }

      # Calculate basic statistics
      memory_stats = calculate_stats(memory_values)
      gc_stats = calculate_stats(gc_counts)
      object_stats = calculate_stats(object_counts)

      # Detect patterns
      memory_trend = calculate_memory_trend(memory_values, samples.map { |s| s[:timestamp] })

      # Analyze recent activity
      recent_samples = samples.last(10)
      recent_controllers = recent_samples.map { |s| "#{s[:controller]}##{s[:action]}" }.tally

      {
        status: "analyzed",
        sample_count: samples.length,
        time_window_seconds: samples.last[:timestamp] - samples.first[:timestamp],
        memory_stats: memory_stats,
        gc_stats: gc_stats,
        object_stats: object_stats,
        memory_trend: memory_trend,
        recent_controllers: recent_controllers,
        leak_alerts: history[:leak_alerts].last(5),
        memory_efficiency: calculate_memory_efficiency(samples)
      }
    end

    def self.calculate_stats(values)
      return {} if values.empty?

      {
        min: values.min,
        max: values.max,
        mean: (values.sum.to_f / values.length).round(2),
        median: values.sort[values.length / 2],
        std_dev: calculate_standard_deviation(values)
      }
    end

    def self.calculate_standard_deviation(values)
      return 0 if values.length < 2

      mean = values.sum.to_f / values.length
      variance = values.sum { |v| (v - mean)**2 } / (values.length - 1)
      Math.sqrt(variance).round(2)
    end

    def self.calculate_memory_efficiency(samples)
      return {} if samples.length < 2

      # Calculate memory per object ratio
      memory_per_object = samples.map do |sample|
        (sample[:object_count] > 0) ? sample[:memory_usage] / sample[:object_count] : 0
      end

      # Calculate GC efficiency (objects collected per GC cycle)
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

    def self.clear_history
      Thread.current[MEMORY_HISTORY_KEY] = nil
    end
  end
end
