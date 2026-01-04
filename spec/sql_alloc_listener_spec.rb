# frozen_string_literal: true

require "spec_helper"
require "dead_bro/sql_subscriber"

RSpec.describe DeadBro::SqlAllocListener do
  let(:listener) { described_class.new }
  let(:event_id) { "test-event-id" }
  let(:alloc_start_key) { DeadBro::SqlSubscriber::THREAD_LOCAL_ALLOC_START_KEY }
  let(:alloc_results_key) { DeadBro::SqlSubscriber::THREAD_LOCAL_ALLOC_RESULTS_KEY }
  let(:backtrace_key) { DeadBro::SqlSubscriber::THREAD_LOCAL_BACKTRACE_KEY }

  before do
    # Clean up thread locals
    Thread.current[alloc_start_key] = nil
    Thread.current[alloc_results_key] = nil
    Thread.current[backtrace_key] = nil
  end

  after do
    Thread.current[alloc_start_key] = nil
    Thread.current[alloc_results_key] = nil
    Thread.current[backtrace_key] = nil
  end

  describe "#start" do
    it "records the starting allocation count" do
      allow(GC).to receive(:stat).and_return({ total_allocated_objects: 1000 })
      
      listener.start("sql.active_record", event_id, {})
      
      start_map = Thread.current[alloc_start_key]
      expect(start_map).not_to be_nil
      expect(start_map[event_id]).to eq(1000)
    end

    it "captures the backtrace" do
      # Mock the backtrace to ensure predictable results and test the slicing logic
      mock_backtrace = [
        "frame1", "frame2", "frame3", "frame4", "frame5", # skipped frames
        "app/models/user.rb:10",
        "app/controllers/users_controller.rb:20"
      ]
      allow(Thread.current).to receive(:backtrace).and_return(mock_backtrace)

      listener.start("sql.active_record", event_id, {})
      
      backtrace_map = Thread.current[backtrace_key]
      expect(backtrace_map).not_to be_nil
      # It should slice the first 5 frames
      expect(backtrace_map[event_id]).to eq(["app/models/user.rb:10", "app/controllers/users_controller.rb:20"])
    end
  end

  describe "#finish" do
    before do
      allow(GC).to receive(:stat).and_return({ total_allocated_objects: 1050 })
    end

    it "calculates allocation delta and stores it" do
      # Setup start state
      Thread.current[alloc_start_key] = { event_id => 1000 }
      
      listener.finish("sql.active_record", event_id, {})
      
      results = Thread.current[alloc_results_key]
      expect(results).not_to be_nil
      expect(results[event_id]).to eq(50) # 1050 - 1000
    end

    it "cleans up the start entry" do
      Thread.current[alloc_start_key] = { event_id => 1000 }
      
      listener.finish("sql.active_record", event_id, {})
      
      expect(Thread.current[alloc_start_key]).not_to have_key(event_id)
    end

    it "does nothing if start data is missing" do
      Thread.current[alloc_start_key] = {}
      
      listener.finish("sql.active_record", event_id, {})
      
      expect(Thread.current[alloc_results_key]).to be_nil
    end
  end
end
