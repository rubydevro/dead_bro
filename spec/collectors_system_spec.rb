#!/usr/bin/env ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Collectors::System do
  describe ".cpu_pct_from_samples" do
    it "computes a cpu percentage between 0 and 100" do
      prev = { "total" => 1000, "idle" => 500 }
      cur  = { "total" => 1100, "idle" => 540 }

      pct = described_class.cpu_pct_from_samples(prev, cur)

      expect(pct).to be_a(Float)
      expect(pct).to be >= 0
      expect(pct).to be <= 100
    end

    it "returns nil when total delta is non-positive" do
      prev = { "total" => 1000, "idle" => 500 }
      cur  = { "total" => 1000, "idle" => 500 }

      pct = described_class.cpu_pct_from_samples(prev, cur)

      expect(pct).to be_nil
    end
  end
  describe "on MacOS" do
    before do
      allow(described_class).to receive(:linux?).and_return(false)
      allow(described_class).to receive(:macos?).and_return(true)
    end

    describe ".cpu_percentage" do
      it "parses top output correctly" do
        top_output = "CPU usage: 10.0% user, 20.0% sys, 70.0% idle"
        allow(described_class).to receive(:`).with('top -l 1 -n 0 | grep "CPU usage"').and_return(top_output)
        
        expect(described_class.cpu_percentage).to eq(30.0) # 100 - 70.0
      end

      it "returns nil on parse error" do
        allow(described_class).to receive(:`).and_return("Invalid Output")
        expect(described_class.cpu_percentage).to be_nil
      end
    end

    describe ".mem_total_bytes" do
      it "uses sysctl" do
        allow(described_class).to receive(:`).with("sysctl -n hw.memsize").and_return("17179869184\n")
        expect(described_class.mem_total_bytes).to eq(17179869184)
      end
    end

    describe ".mem_available_bytes" do
      it "parses vm_stat correctly" do
        vm_stat_output = <<~OUTPUT
          Mach Virtual Memory Statistics: (page size of 4096 bytes)
          Pages free:                               3632.
          Pages active:                           138466.
          Pages inactive:                         134812.
          Pages speculative:                       1234.
        OUTPUT
        allow(described_class).to receive(:`).with("vm_stat").and_return(vm_stat_output)

        # Free (3632) + Inactive (134812) = 138444 pages
        # 138444 * 4096 = 567066624 bytes
        expected = (3632 + 134812) * 4096
        expect(described_class.mem_available_bytes).to eq(expected)
      end
    end
  end
end

