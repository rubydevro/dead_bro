# frozen_string_literal: true

require "spec_helper"

RSpec.describe "DeadBro.analyze memory_details format" do
  before { allow($stdout).to receive(:puts) }

  subject(:details) { DeadBro.analyze("test") { nil }[:memory_details] }

  describe "key names" do
    it "uses gc_collections not gc_runs" do
      expect(details).to have_key(:gc_collections)
      expect(details).not_to have_key(:gc_runs)
    end

    it "uses heap_pages_added not heap_pages_delta" do
      expect(details).to have_key(:heap_pages_added)
      expect(details).not_to have_key(:heap_pages_delta)
    end

    it "uses new_objects not objects_allocated" do
      expect(details).to have_key(:new_objects)
      expect(details).not_to have_key(:objects_allocated)
    end

    it "uses object_breakdown not object_type_deltas" do
      expect(details).to have_key(:object_breakdown)
      expect(details).not_to have_key(:object_type_deltas)
    end

    it "uses warnings not memory_warnings" do
      expect(details).to have_key(:warnings)
      expect(details).not_to have_key(:memory_warnings)
    end
  end

  describe "object_breakdown" do
    let(:raw_deltas) do
      {
        FREE: -21711,
        T_IMEMO: 9295,
        T_STRING: 8747,
        T_ARRAY: 3532,
        TOTAL: 3272,
        T_DATA: 1367,
        T_HASH: 957,
        T_OBJECT: 410,
        T_CLASS: 184,
        T_MATCH: 184
      }
    end

    subject(:breakdown) do
      DeadBro::MemoryDetails.format_object_breakdown(raw_deltas)
    end

    it "maps T_STRING to String" do
      expect(breakdown).to include("String" => 8747)
    end

    it "maps T_ARRAY to Array" do
      expect(breakdown).to include("Array" => 3532)
    end

    it "maps T_HASH to Hash" do
      expect(breakdown).to include("Hash" => 957)
    end

    it "maps T_OBJECT to Object" do
      expect(breakdown).to include("Object" => 410)
    end

    it "maps T_CLASS to Class" do
      expect(breakdown).to include("Class" => 184)
    end

    it "maps T_DATA to C Extension" do
      expect(breakdown).to include("C Extension" => 1367)
    end

    it "maps T_MATCH to MatchData" do
      expect(breakdown).to include("MatchData" => 184)
    end

    it "excludes FREE (internal slot bookkeeping)" do
      expect(breakdown.keys).not_to include("FREE")
      expect(breakdown.keys).not_to include(:FREE)
    end

    it "excludes T_IMEMO (internal Ruby memo objects)" do
      expect(breakdown.keys).not_to include("Internal")
      expect(breakdown.keys).not_to include(:T_IMEMO)
    end

    it "excludes TOTAL (redundant sum)" do
      expect(breakdown.keys).not_to include("TOTAL")
      expect(breakdown.keys).not_to include(:TOTAL)
    end

    it "only shows positive deltas (net new objects)" do
      expect(breakdown.values).to all(be_positive)
    end

    it "sorts by count descending" do
      values = breakdown.values
      expect(values).to eq(values.sort.reverse)
    end
  end

  describe "warnings" do
    it "warns on large memory growth (>20MB)" do
      call_count = 0
      allow(DeadBro::MemoryHelpers).to receive(:rss_mb) do
        call_count += 1
        call_count == 1 ? 100.0 : 125.0
      end

      result = DeadBro.analyze("test") { nil }
      expect(result[:memory_details][:warnings]).to include(
        a_string_matching(/memory grew/i)
      )
    end

    it "warns on high GC pressure (>5 runs)" do
      call_count = 0
      allow(GC).to receive(:stat) do
        call_count += 1
        call_count == 1 ? {count: 10, heap_allocated_pages: 100, total_allocated_objects: 1000} :
                          {count: 17, heap_allocated_pages: 100, total_allocated_objects: 2000}
      end

      result = DeadBro.analyze("test") { nil }
      expect(result[:memory_details][:warnings]).to include(
        a_string_matching(/gc ran \d+ times/i)
      )
    end

    it "warns on heap expansion (>10 new pages)" do
      call_count = 0
      allow(GC).to receive(:stat) do
        call_count += 1
        call_count == 1 ? {count: 5, heap_allocated_pages: 100, total_allocated_objects: 1000} :
                          {count: 5, heap_allocated_pages: 115, total_allocated_objects: 2000}
      end

      result = DeadBro.analyze("test") { nil }
      expect(result[:memory_details][:warnings]).to include(
        a_string_matching(/heap grew/i)
      )
    end
  end
end
