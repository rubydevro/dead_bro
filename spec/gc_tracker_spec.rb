# frozen_string_literal: true

require "spec_helper"
require "dead_bro/gc_tracker"

RSpec.describe DeadBro::GcTracker do
  after { Thread.current[described_class::THREAD_KEY] = nil }

  describe ".snapshot" do
    it "returns a hash with the expected keys" do
      snap = described_class.snapshot
      expect(snap).to include(:minor_gc_count, :major_gc_count, :total_allocated_objects, :gc_time_ns)
    end

    it "returns {} when GC.stat raises" do
      allow(GC).to receive(:stat).and_raise(RuntimeError)
      expect(described_class.snapshot).to eq({})
    end
  end

  describe ".diff" do
    let(:before) { { minor_gc_count: 10, major_gc_count: 2, total_allocated_objects: 1000, gc_time_ns: 5_000_000 } }
    let(:after)  { { minor_gc_count: 13, major_gc_count: 3, total_allocated_objects: 1200, gc_time_ns: 8_000_000 } }

    it "computes deltas correctly" do
      result = described_class.diff(before, after)
      expect(result[:minor_gc_runs]).to eq(3)
      expect(result[:major_gc_runs]).to eq(1)
      expect(result[:allocated_objects]).to eq(200)
    end

    it "converts gc_time_ns to gc_time_ms" do
      result = described_class.diff(before, after)
      expect(result[:gc_time_ms]).to eq(3.0)
    end

    it "returns nil gc_time_ms when gc_time_ns is absent" do
      b = before.merge(gc_time_ns: nil)
      a = after.merge(gc_time_ns: nil)
      expect(described_class.diff(b, a)[:gc_time_ms]).to be_nil
    end

    it "returns {} for empty before" do
      expect(described_class.diff({}, after)).to eq({})
    end

    it "returns {} for empty after" do
      expect(described_class.diff(before, {})).to eq({})
    end
  end

  describe ".start_request_tracking / .stop_request_tracking" do
    it "returns {} when stop called without start" do
      expect(described_class.stop_request_tracking).to eq({})
    end

    it "returns {} when start snapshot errored (nil thread key)" do
      Thread.current[described_class::THREAD_KEY] = nil
      expect(described_class.stop_request_tracking).to eq({})
    end

    it "returns a diff hash after a start/stop round-trip" do
      described_class.start_request_tracking
      result = described_class.stop_request_tracking
      expect(result).to include(:minor_gc_runs, :major_gc_runs, :allocated_objects)
    end

    it "clears the thread key after stop" do
      described_class.start_request_tracking
      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end

    it "clears the thread key even when diff raises" do
      described_class.start_request_tracking
      allow(described_class).to receive(:snapshot).and_raise(RuntimeError)
      described_class.stop_request_tracking rescue nil
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end
  end
end
