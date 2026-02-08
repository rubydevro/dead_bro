# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::LightweightMemoryTracker do
  let(:tracker) { DeadBro::LightweightMemoryTracker }

  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.memory_tracking_enabled = true
  end

  after do
    # Clean up thread local so other specs are not affected
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
  end

  describe ".start_request_tracking" do
    it "pushes a frame onto the stack" do
      tracker.start_request_tracking
      stack = Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY]
      expect(stack).to be_a(Array)
      expect(stack.size).to eq(1)
      expect(stack.first).to include(:memory_before, :gc_before, :start_time)
    end

    it "does nothing when memory_tracking_enabled is false" do
      DeadBro.configuration.memory_tracking_enabled = false
      tracker.start_request_tracking
      expect(Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY]).to be_nil
    end
  end

  describe ".stop_request_tracking" do
    it "returns empty hash when no tracking was started" do
      result = tracker.stop_request_tracking
      expect(result).to eq({})
    end

    it "returns memory metrics for a single frame" do
      tracker.start_request_tracking
      result = tracker.stop_request_tracking

      expect(result).to include(:memory_before, :memory_after, :memory_growth_mb, :duration_seconds)
      expect(result[:memory_before]).to be_a(Numeric)
      expect(result[:memory_after]).to be_a(Numeric)
      expect(Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY]).to be_nil
    end
  end

  describe "nested job tracking (stack)" do
    it "isolates frames per nested level" do
      tracker.start_request_tracking
      outer_before = Thread.current[tracker::THREAD_LOCAL_KEY].last[:memory_before]

      tracker.start_request_tracking
      expect(Thread.current[tracker::THREAD_LOCAL_KEY].size).to eq(2)

      # Stop inner frame
      inner = tracker.stop_request_tracking
      expect(inner).to include(:memory_before, :memory_after)
      expect(Thread.current[tracker::THREAD_LOCAL_KEY].size).to eq(1)

      # Stop outer frame
      outer = tracker.stop_request_tracking
      expect(outer).to include(:memory_before, :memory_after)
      expect(outer[:memory_before]).to eq(outer_before)
      expect(Thread.current[tracker::THREAD_LOCAL_KEY]).to be_nil
    end

    it "clears thread local when stack is empty after pop" do
      tracker.start_request_tracking
      tracker.stop_request_tracking
      expect(Thread.current[tracker::THREAD_LOCAL_KEY]).to be_nil

      # Second stop returns empty (no frame)
      expect(tracker.stop_request_tracking).to eq({})
    end
  end
end
