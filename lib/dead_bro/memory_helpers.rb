# frozen_string_literal: true

module DeadBro
  module MemoryHelpers
    # Helper methods for memory tracking and leak detection

    # Take a memory snapshot with a custom label
    def self.snapshot(label)
      DeadBro::MemoryTrackingSubscriber.take_memory_snapshot(label)
    end

    # Get current memory analysis
    def self.analyze_memory
      DeadBro::MemoryLeakDetector.get_memory_analysis
    end

    # Check for memory leaks
    def self.check_for_leaks
      analysis = analyze_memory
      if analysis[:leak_alerts]&.any?
        puts "🚨 Memory leak detected!"
        analysis[:leak_alerts].each do |alert|
          puts "  - Growth: #{alert[:memory_growth_mb]}MB"
          puts "  - Rate: #{alert[:growth_rate_mb_per_second]}MB/sec"
          puts "  - Confidence: #{(alert[:confidence] * 100).round(1)}%"
          puts "  - Recent controllers: #{alert[:recent_controllers].join(", ")}"
        end
      else
        puts "✅ No memory leaks detected"
      end
      analysis
    end

    # Get memory usage summary
    def self.memory_summary
      analysis = analyze_memory
      return "Insufficient data" if analysis[:status] == "insufficient_data"

      memory_stats = analysis[:memory_stats]
      puts "📊 Memory Summary:"
      puts "  - Current: #{memory_stats[:mean]}MB (avg)"
      puts "  - Range: #{memory_stats[:min]}MB - #{memory_stats[:max]}MB"
      puts "  - Volatility: #{memory_stats[:std_dev]}MB"
      puts "  - Samples: #{analysis[:sample_count]}"

      if analysis[:memory_trend][:slope] > 0
        puts "  - Trend: ↗️ Growing at #{analysis[:memory_trend][:slope].round(3)}MB/sec"
      elsif analysis[:memory_trend][:slope] < 0
        puts "  - Trend: ↘️ Shrinking at #{analysis[:memory_trend][:slope].abs.round(3)}MB/sec"
      else
        puts "  - Trend: ➡️ Stable"
      end

      analysis
    end

    # Monitor memory during a block execution
    def self.monitor_memory(label, &block)
      snapshot("before_#{label}")
      result = yield
      snapshot("after_#{label}")

      # Get the difference
      analysis = analyze_memory
      if analysis[:memory_stats]
        puts "🔍 Memory monitoring for '#{label}':"
        puts "  - Memory change: #{analysis[:memory_stats][:max] - analysis[:memory_stats][:min]}MB"
        puts "  - Peak usage: #{analysis[:memory_stats][:max]}MB"
      end

      result
    end

    # Clear memory history (useful for testing)
    def self.clear_history
      DeadBro::MemoryLeakDetector.clear_history
    end

    # Get top memory allocating classes
    def self.top_allocators
      # This would need to be called from within a request context
      # where memory_events are available
      puts "Top memory allocators:"
      puts "  (Call this from within a request to see allocation data)"
    end
  end
end
