#!/usr/bin/env ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Collectors::Jobs do
  describe ".collect" do
    before do
      DeadBro.reset_configuration!
    end

    it "returns a hash with top-level metadata" do
      stub_const("Sidekiq", Module.new)

      payload = described_class.collect

      expect(payload).to be_a(Hash)
    end

    it "includes Sidekiq stats when Sidekiq is defined" do
      sidekiq_mod = Module.new
      stub_const("Sidekiq", sidekiq_mod)

      stats_double = instance_double("Sidekiq::Stats",
        processed: 10,
        failed: 1,
        enqueued: 3,
        scheduled_size: 2,
        retry_size: 1,
        dead_size: 0,
        workers_size: 1,
        processes_size: 1)

      queue = double("Sidekiq::Queue", name: "default", size: 3, latency: 1.5)
      queue_class = double("Sidekiq::QueueClass", all: [queue])

      stub_const("Sidekiq::Stats", Class.new)
      allow(Sidekiq::Stats).to receive(:new).and_return(stats_double)
      allow(Sidekiq).to receive(:const_get).with(:Queue).and_return(queue_class)
      allow(described_class).to receive(:safe_sidekiq_stats).and_return(stats_double)

      payload = described_class.collect

      expect(payload[:queue_system]).to eq(:sidekiq)
      expect(payload[:queue]).to include(
        processed: 10,
        failed: 1,
        enqueued: 3,
        scheduled_size: 2,
        retry_size: 1,
        dead_size: 0
      )
      expect(payload[:queue][:queues]).to be_an(Array)
      first_queue = payload[:queue][:queues].first
      expect(first_queue[:name]).to eq("default")
      expect(first_queue[:size]).to eq(3)
      expect(first_queue[:latency_s]).to eq(1.5)
    end
  end

  describe ".detect_queue_system" do
    it "detects Sidekiq when available" do
      stub_const("Sidekiq", Module.new)
      expect(described_class.detect_queue_system).to eq(:sidekiq)
    end

    it "detects SolidQueue when available" do
      stub_const("SolidQueue", Module.new)
      expect(described_class.detect_queue_system).to eq(:solid_queue)
    end

    it "detects Delayed::Job when available" do
      stub_const("Delayed::Job", Class.new)
      expect(described_class.detect_queue_system).to eq(:delayed_job)
    end

    it "detects GoodJob when available" do
      stub_const("GoodJob", Module.new)
      expect(described_class.detect_queue_system).to eq(:good_job)
    end

    it "returns unknown when no queue system is detected" do
      expect(described_class.detect_queue_system).to eq(:unknown)
    end

    it "prioritizes Sidekiq over other systems" do
      stub_const("Sidekiq", Module.new)
      stub_const("SolidQueue", Module.new)
      expect(described_class.detect_queue_system).to eq(:sidekiq)
    end
  end

  describe ".collect_sidekiq_stats" do
    let(:sidekiq_queue) { double("Sidekiq::Queue", name: "default", size: 10, latency: 0.5) }
    let(:sidekiq_queue_class) { double("Sidekiq::Queue", all: [sidekiq_queue]) }
    let(:sidekiq_stats) do
      instance_double("Sidekiq::Stats",
        processed: 100,
        failed: 5,
        enqueued: 10,
        scheduled_size: 2,
        retry_size: 3,
        dead_size: 1,
        workers_size: 4,
        processes_size: 1)
    end

    context "when Sidekiq is not defined" do
      it "returns empty hash" do
        skip "Sidekiq is defined in test environment" if defined?(Sidekiq)
        expect(described_class.collect_sidekiq_stats).to eq({})
      end
    end

    context "when Sidekiq is defined" do
      before do
        stub_const("Sidekiq", Module.new)
        stub_const("Sidekiq::Stats", Class.new)
      end

      it "collects queue statistics" do
        allow(Sidekiq::Stats).to receive(:new).and_return(sidekiq_stats)
        allow(Sidekiq).to receive(:const_get).with(:Queue).and_return(sidekiq_queue_class)
        allow(described_class).to receive(:safe_sidekiq_stats).and_return(sidekiq_stats)

        stats = described_class.collect_sidekiq_stats

        expect(stats[:processed]).to eq(100)
        expect(stats[:failed]).to eq(5)
        expect(stats[:enqueued]).to eq(10)
        expect(stats[:queues]).to be_an(Array)
        expect(stats[:queues].first[:name]).to eq("default")
        expect(stats[:queues].first[:size]).to eq(10)
      end

      it "handles errors gracefully" do
        allow(described_class).to receive(:safe_sidekiq_stats).and_raise(StandardError.new("Sidekiq Error"))

        stats = described_class.collect_sidekiq_stats

        expect(stats[:error_class]).to eq("StandardError")
        expect(stats[:error_message]).to include("Sidekiq Error")
      end
    end
  end

  describe ".collect_solid_queue_stats" do
    let(:connection) { double("ActiveRecord::Base.connection") }
    let(:query_result) { [{"queue_name" => "default", "count" => "5"}] }

    before do
      stub_const("SolidQueue", Module.new)
      ar_module = Module.new
      base_class = Class.new
      stub_const("ActiveRecord", ar_module)
      stub_const("ActiveRecord::Base", base_class)
      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(connection).to receive(:table_exists?).and_return(true)
    end

    it "collects queue statistics from database" do
      # Queued
      allow(connection).to receive(:execute).with(/WHERE finished_at IS NULL GROUP BY/).and_return(query_result)
      # Busy
      allow(connection).to receive(:execute).with(/WHERE finished_at IS NULL AND claimed_at IS NOT NULL/).and_return([])
      # Scheduled
      allow(connection).to receive(:execute).with(/WHERE scheduled_at >/).and_return([{"count" => "0"}])
      # Failed
      allow(connection).to receive(:execute).with(/FROM solid_queue_failed_jobs/).and_return([{"count" => "0"}])

      stats = described_class.collect_solid_queue_stats

      expect(stats[:total_queued]).to eq(5)
      expect(stats[:queues]["default"][:queued]).to eq(5)
    end

    it "handles missing ActiveRecord connection" do
      allow(ActiveRecord::Base).to receive(:connected?).and_return(false)
      expect(described_class.collect_solid_queue_stats).to eq({})
    end
  end

  describe ".collect_delayed_job_stats" do
    let(:delayed_job_class) { double("Delayed::Job") }
    let(:connection) { double("ActiveRecord::Base.connection", table_exists?: true) }

    before do
      stub_const("Delayed::Job", delayed_job_class)
      ar_module = Module.new
      base_class = Class.new
      stub_const("ActiveRecord", ar_module)
      stub_const("ActiveRecord::Base", base_class)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    end

    it "collects job statistics" do
      queued_relation = double("Relation", count: 5)
      allow(delayed_job_class).to receive(:where).with("locked_at IS NULL AND attempts < max_attempts").and_return(queued_relation)

      busy_relation = double("Relation", count: 2)
      allow(delayed_job_class).to receive(:where).with("locked_at IS NOT NULL AND locked_by IS NOT NULL").and_return(busy_relation)

      failed_relation = double("Relation", count: 1)
      allow(delayed_job_class).to receive(:where).with("attempts >= max_attempts").and_return(failed_relation)

      stats = described_class.collect_delayed_job_stats

      expect(stats[:total_queued]).to eq(5)
      expect(stats[:total_busy]).to eq(2)
      expect(stats[:total_failed]).to eq(1)
    end
  end

  describe ".collect_good_job_stats" do
    let(:connection) { double("ActiveRecord::Base.connection") }
    let(:query_result) { [{"queue_name" => "default", "count" => "3"}] }

    before do
      stub_const("GoodJob", Module.new)
      ar_module = Module.new
      base_class = Class.new
      stub_const("ActiveRecord", ar_module)
      stub_const("ActiveRecord::Base", base_class)
      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(connection).to receive(:table_exists?).and_return(true)
    end

    it "collects queue statistics from database" do
      # Queued
      allow(connection).to receive(:execute).with(/WHERE finished_at IS NULL GROUP BY/).and_return(query_result)
      # Busy
      allow(connection).to receive(:execute).with(/WHERE finished_at IS NULL AND performed_at IS NOT NULL/).and_return([])
      # Scheduled
      allow(connection).to receive(:execute).with(/WHERE scheduled_at >/).and_return([{"count" => "0"}])
      # Failed
      allow(connection).to receive(:execute).with(/WHERE finished_at IS NOT NULL AND error/).and_return([{"count" => "0"}])

      stats = described_class.collect_good_job_stats

      expect(stats[:total_queued]).to eq(3)
      expect(stats[:queues]["default"][:queued]).to eq(3)
    end
  end
end
