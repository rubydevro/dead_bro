# frozen_string_literal: true

require "spec_helper"
require "dead_bro/cpu_tracker"

RSpec.describe DeadBro::CpuTracker do
  after { Thread.current[described_class::THREAD_KEY] = nil }

  describe ".thread_cpu_ms" do
    it "returns a numeric value" do
      expect(described_class.thread_cpu_ms).to be_a(Numeric)
    end

    it "returns a non-negative value" do
      expect(described_class.thread_cpu_ms).to be >= 0
    end

    it "returns nil when clock_gettime raises" do
      allow(Process).to receive(:clock_gettime).and_raise(Errno::EINVAL)
      expect(described_class.thread_cpu_ms).to be_nil
    end
  end

  describe ".start_request_tracking" do
    it "sets the thread-local key to a numeric value" do
      described_class.start_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_a(Numeric)
    end
  end

  describe ".stop_request_tracking" do
    it "returns nil when called without a prior start" do
      expect(described_class.stop_request_tracking).to be_nil
    end

    it "returns a non-negative number after a start/stop round-trip" do
      described_class.start_request_tracking
      result = described_class.stop_request_tracking
      expect(result).to be_a(Numeric)
      expect(result).to be >= 0
    end

    it "clears the thread-local key after stop" do
      described_class.start_request_tracking
      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end

    it "clears the thread-local key even when thread_cpu_ms returns nil on stop" do
      described_class.start_request_tracking
      call_count = 0
      allow(described_class).to receive(:thread_cpu_ms) do
        call_count += 1
        call_count == 1 ? 10.0 : nil  # second call (stop) returns nil
      end
      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end

    it "returns nil when thread_cpu_ms is unavailable at stop time" do
      described_class.start_request_tracking
      allow(described_class).to receive(:thread_cpu_ms).and_return(nil)
      expect(described_class.stop_request_tracking).to be_nil
    end

    it "increases monotonically over CPU work" do
      described_class.start_request_tracking
      1_000_000.times { |i| i * 2 }
      result = described_class.stop_request_tracking
      expect(result).to be > 0
    end
  end
end
