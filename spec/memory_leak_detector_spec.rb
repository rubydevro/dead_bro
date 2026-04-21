# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::MemoryLeakDetector do
  before { described_class.clear_history }
  after  { described_class.clear_history }

  # ---------------------------------------------------------------------------
  # calculate_memory_trend
  # ---------------------------------------------------------------------------
  describe ".calculate_memory_trend" do
    it "returns zero slope for flat memory" do
      timestamps = [0, 60, 120, 180, 240]
      memory     = [100.0, 100.0, 100.0, 100.0, 100.0]

      result = described_class.calculate_memory_trend(memory, timestamps)

      expect(result[:slope]).to be_within(0.001).of(0.0)
    end

    it "detects a clear upward trend when using real epoch timestamps" do
      # Simulate 10 samples spread over 5 minutes with +10 MB each minute.
      # Using raw Unix timestamps exposes the catastrophic-cancellation bug:
      # the old code would return a slope indistinguishable from noise.
      t0 = 1_700_000_000 # realistic epoch value
      timestamps = (0..9).map { |i| t0 + i * 30 }
      memory     = (0..9).map { |i| 100.0 + i * 5.0 } # 5 MB per 30 s

      result = described_class.calculate_memory_trend(memory, timestamps)

      # Slope must be clearly positive and roughly 5/30 ≈ 0.166 MB/s
      expect(result[:slope]).to be > 0.1
      expect(result[:r_squared]).to be > 0.99
    end

    it "detects a clear downward trend" do
      t0 = 1_700_000_000
      timestamps = (0..9).map { |i| t0 + i * 30 }
      memory     = (0..9).map { |i| 200.0 - i * 5.0 }

      result = described_class.calculate_memory_trend(memory, timestamps)

      expect(result[:slope]).to be < -0.1
      expect(result[:r_squared]).to be > 0.99
    end

    it "returns slope: 0 and r_squared: 0 for fewer than 2 samples" do
      result = described_class.calculate_memory_trend([100.0], [1_700_000_000])
      expect(result).to eq({slope: 0, r_squared: 0})
    end
  end

  # ---------------------------------------------------------------------------
  # record_memory_sample / leak detection runs outside the mutex
  # ---------------------------------------------------------------------------
  describe ".record_memory_sample" do
    it "records samples and makes them visible in get_memory_analysis" do
      5.times do |i|
        described_class.record_memory_sample(
          memory_usage: 100.0 + i,
          gc_count: i,
          heap_pages: 10,
          object_count: 1000 + i
        )
      end

      analysis = described_class.get_memory_analysis
      expect(analysis[:status]).to eq("analyzed")
      expect(analysis[:sample_count]).to eq(5)
    end

    it "caps samples at MAX_SAMPLES to prevent unbounded growth" do
      (DeadBro::MemoryLeakDetector::MAX_SAMPLES + 50).times do |i|
        described_class.record_memory_sample(
          memory_usage: 100.0,
          gc_count: 0,
          heap_pages: 0,
          object_count: 0
        )
      end

      analysis = described_class.get_memory_analysis
      expect(analysis[:sample_count]).to be <= DeadBro::MemoryLeakDetector::MAX_SAMPLES
    end

    it "detects a memory leak and records an alert" do
      # Feed 15 samples with a strong upward trend exceeding MEMORY_GROWTH_THRESHOLD
      t0 = Time.now.utc.to_i
      15.times do |i|
        allow(Time).to receive(:now).and_return(
          Time.at(t0 + i * 20).utc
        )
        described_class.record_memory_sample(
          memory_usage: 100.0 + i * 6.0, # 6 MB per 20 s → slope 0.3 MB/s, growth 84 MB
          gc_count: 0,
          heap_pages: 0,
          object_count: 0
        )
      end

      analysis = described_class.get_memory_analysis
      expect(analysis[:leak_alerts]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # get_memory_analysis
  # ---------------------------------------------------------------------------
  describe ".get_memory_analysis" do
    it "returns insufficient_data when fewer than 5 samples" do
      3.times do
        described_class.record_memory_sample(memory_usage: 100.0, gc_count: 0, heap_pages: 0, object_count: 0)
      end

      result = described_class.get_memory_analysis
      expect(result[:status]).to eq("insufficient_data")
      expect(result[:sample_count]).to eq(3)
    end

    it "includes memory_stats, gc_stats, and memory_trend keys when analyzed" do
      10.times do |i|
        described_class.record_memory_sample(
          memory_usage: 100.0 + i,
          gc_count: i,
          heap_pages: 10,
          object_count: 1000
        )
      end

      result = described_class.get_memory_analysis
      expect(result).to include(:memory_stats, :gc_stats, :memory_trend, :object_stats, :memory_efficiency)
    end
  end

  # ---------------------------------------------------------------------------
  # clear_history
  # ---------------------------------------------------------------------------
  describe ".clear_history" do
    it "resets all samples and alerts" do
      5.times do
        described_class.record_memory_sample(memory_usage: 100.0, gc_count: 0, heap_pages: 0, object_count: 0)
      end

      described_class.clear_history

      result = described_class.get_memory_analysis
      expect(result[:status]).to eq("insufficient_data")
      expect(result[:sample_count]).to eq(0)
    end
  end
end
