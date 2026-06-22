# frozen_string_literal: true

require "spec_helper"
require "dead_bro/profiler"

RSpec.describe DeadBro::Profiler do
  after { Thread.current[described_class::MODE_KEY] = nil }

  describe ".pick_mode" do
    it "alternates between :wall and :object" do
      modes = Array.new(4) { described_class.pick_mode }
      expect(modes.uniq).to contain_exactly(:wall, :object)
      # Consecutive picks differ (rotation, not random).
      expect(modes[0]).not_to eq(modes[1])
    end
  end

  describe ".summarize" do
    it "returns sample count and top frames sorted by self samples" do
      dump = {
        samples: 8,
        frames: {
          1 => {name: "Slow#a", samples: 5, total_samples: 8},
          2 => {name: "Fast#b", samples: 3, total_samples: 3}
        }
      }
      summary = described_class.summarize(dump, mode: :wall, interval: 1000)
      expect(summary[:mode]).to eq("wall")
      expect(summary[:interval]).to eq(1000)
      expect(summary[:sample_count]).to eq(8)
      expect(summary[:top_frames].first[:name]).to eq("Slow#a")
      expect(summary[:top_frames].map { |f| f[:name] }).to eq(["Slow#a", "Fast#b"])
    end

    it "returns nil for a non-hash dump" do
      expect(described_class.summarize(nil, mode: :wall, interval: 1000)).to be_nil
    end
  end

  context "when stackprof is unavailable (no-op path)" do
    before { allow(described_class).to receive(:available?).and_return(false) }

    it "start returns false" do
      expect(described_class.start(:wall)).to be(false)
    end

    it "stop returns nil" do
      expect(described_class.stop).to be_nil
    end

    it "collect returns nil even when a mode is set" do
      Thread.current[described_class::MODE_KEY] = :wall
      expect(described_class.collect(max_bytes: 1000)).to be_nil
    end
  end

  # Real end-to-end capture against the actual stackprof C extension. Skipped
  # automatically where stackprof can't load (and on the prod Linux gate this is
  # the real path). stackprof is in the gem's Gemfile for exactly this.
  context "with the real stackprof extension", if: (require("stackprof") rescue false) do
    around do |example|
      real = DeadBro::Profiler.respond_to?(:available?)
      DeadBro::Profiler.define_singleton_method(:available?) { true }
      example.run
    ensure
      DeadBro::Profiler.singleton_class.send(:remove_method, :available?)
    end

    after { Thread.current[described_class::MODE_KEY] = nil }

    def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)

    it "captures a real wall-mode profile and summarizes it" do
      expect(described_class.start(:wall)).to be(true)
      Thread.current[described_class::MODE_KEY] = :wall
      5.times { fib(25) }
      result = described_class.collect(max_bytes: 5_000_000)

      expect(result[:mode]).to eq("wall")
      expect(result[:summary][:sample_count]).to be > 0
      expect(result[:raw]).to be_a(Hash)
      expect(result[:raw][:frames]).to be_a(Hash)
      expect(result[:raw][:raw]).to be_an(Array)
      expect(Thread.current[described_class::MODE_KEY]).to be_nil
    end

    it "drops the raw blob over the cap but keeps the summary" do
      described_class.start(:wall)
      Thread.current[described_class::MODE_KEY] = :wall
      5.times { fib(25) }
      result = described_class.collect(max_bytes: 50)
      expect(result[:raw]).to be_nil
      expect(result[:raw_dropped]).to be(true)
      expect(result[:summary][:sample_count]).to be > 0
    end
  end

  context "when stackprof is available (stubbed)" do
    let(:fake_dump) do
      {samples: 4, frames: {1 => {name: "App#work", samples: 4, total_samples: 4}}}
    end
    let(:stackprof) { class_double("StackProf") }

    before do
      allow(described_class).to receive(:available?).and_return(true)
      stub_const("StackProf", stackprof)
      allow(stackprof).to receive(:running?).and_return(false)
      allow(stackprof).to receive(:start).and_return(true)
      allow(stackprof).to receive(:stop)
      allow(stackprof).to receive(:results).and_return(fake_dump)
    end

    it "start passes raw + ignore_gc + interval to StackProf" do
      expect(stackprof).to receive(:start).with(mode: :object, raw: true, interval: 1, ignore_gc: true)
      described_class.start(:object)
    end

    it "start refuses to nest when already running" do
      allow(stackprof).to receive(:running?).and_return(true)
      expect(stackprof).not_to receive(:start)
      expect(described_class.start(:wall)).to be(false)
    end

    it "collect returns summary + raw and clears MODE_KEY" do
      Thread.current[described_class::MODE_KEY] = :wall
      allow(stackprof).to receive(:running?).and_return(true)
      result = described_class.collect(max_bytes: 1_000_000)
      expect(result[:mode]).to eq("wall")
      expect(result[:raw]).to eq(fake_dump)
      expect(result[:summary][:sample_count]).to eq(4)
      expect(Thread.current[described_class::MODE_KEY]).to be_nil
    end

    it "collect drops the raw blob when it exceeds max_bytes but keeps the summary" do
      Thread.current[described_class::MODE_KEY] = :wall
      allow(stackprof).to receive(:running?).and_return(true)
      result = described_class.collect(max_bytes: 1)
      expect(result[:raw]).to be_nil
      expect(result[:raw_dropped]).to be(true)
      expect(result[:summary][:sample_count]).to eq(4)
    end
  end
end
