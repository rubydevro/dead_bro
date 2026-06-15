# frozen_string_literal: true

require "spec_helper"
require "dead_bro/allocation_source_sampler"

RSpec.describe DeadBro::AllocationSourceSampler do
  describe ".analyze" do
    it "skips the walk when growth is below the threshold" do
      result = described_class.analyze(memory_growth_mb: 5, min_growth_mb: 50)
      expect(result[:skipped]).to eq("memory_growth_below_threshold")
    end

    context "when ObjectSpace tracing is available", if: described_class.available? do
      it "produces by-type-bytes and by-source breakdowns" do
        described_class.start
        retained = Array.new(20_000) { "payload-string-#{rand}" }
        result = described_class.analyze(memory_growth_mb: 100, min_growth_mb: 0)
        described_class.stop

        expect(result[:sample_rate]).to eq(described_class::SAMPLE_RATE)
        expect(result[:by_type_bytes]).to be_an(Array)
        expect(result[:by_source]).to be_an(Array)
        # Each entry carries a human-readable name plus count + byte size.
        result[:by_type_bytes].each do |entry|
          expect(entry).to include(:name, :count, :bytes, :mb)
        end
        retained.clear
      end
    end

    it "returns {} when ObjectSpace is unavailable" do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class.analyze(memory_growth_mb: 100, min_growth_mb: 0)).to eq({})
    end
  end

  describe ".start / .stop" do
    it "never raises" do
      expect { described_class.start }.not_to raise_error
      expect { described_class.stop }.not_to raise_error
    end
  end
end
