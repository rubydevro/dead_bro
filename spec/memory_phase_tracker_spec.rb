# frozen_string_literal: true

require "spec_helper"
require "dead_bro/memory_phase_tracker"

RSpec.describe DeadBro::MemoryPhaseTracker do
  after { Thread.current[described_class::THREAD_KEY] = nil }

  describe ".stop_request_tracking" do
    it "returns {} when no tracking was started" do
      expect(described_class.stop_request_tracking).to eq({})
    end

    it "clears the thread key after stop" do
      described_class.start_request_tracking
      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end
  end

  describe "exclusive allocation accounting" do
    it "attributes allocations to the active phase" do
      described_class.start_request_tracking
      described_class.enter(:elasticsearch)
      5_000.times { {a: 1} }
      described_class.leave(:elasticsearch)

      result = described_class.stop_request_tracking
      expect(result[:elasticsearch]).to be > 4_000
    end

    it "charges nested phases exclusively (no double counting)" do
      described_class.start_request_tracking
      described_class.enter(:view)
      1_000.times { "x" }
      described_class.enter(:sql)        # nested inside view
      10_000.times { Object.new }
      described_class.leave(:sql)
      described_class.leave(:view)

      result = described_class.stop_request_tracking
      # The 10k objects belong to :sql only, so :sql outweighs :view despite
      # :view being the outer phase.
      expect(result[:sql]).to be > result[:view]
    end

    it "omits phases that allocated nothing" do
      described_class.start_request_tracking
      described_class.enter(:sql)
      described_class.leave(:sql)
      expect(described_class.stop_request_tracking).not_to have_key(:redis)
    end
  end

  describe "guards" do
    it "enter/leave are no-ops when tracking was never started" do
      expect { described_class.enter(:sql) }.not_to raise_error
      expect { described_class.leave(:sql) }.not_to raise_error
    end
  end
end
