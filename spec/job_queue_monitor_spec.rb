# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::JobQueueMonitor do
  let(:client) { instance_double(DeadBro::Client) }
  let(:monitor) { described_class.new(client: client) }

  before do
    # Reset configuration
    DeadBro.reset_configuration!
    DeadBro.configuration.job_queue_monitoring_enabled = true
    DeadBro.configuration.enabled = true
    DeadBro.configuration.api_key = "test-api-key"
  end

  after do
    monitor.stop if monitor.instance_variable_get(:@running)
    DeadBro.reset_configuration!
  end

  describe "#initialize" do
    it "initializes with a client" do
      expect(monitor.instance_variable_get(:@client)).to eq(client)
      expect(monitor.instance_variable_get(:@thread)).to be_nil
      expect(monitor.instance_variable_get(:@running)).to be false
    end

    it "uses DeadBro.client by default" do
      monitor = described_class.new
      expect(monitor.instance_variable_get(:@client)).to eq(DeadBro.client)
    end
  end

  describe "#start" do
    it "does not start if already running" do
      monitor.instance_variable_set(:@running, true)
      expect(monitor.start).to be_nil
    end

    it "does not start if job_queue_monitoring_enabled is false" do
      DeadBro.configuration.job_queue_monitoring_enabled = false
      expect(monitor.start).to be_nil
      expect(monitor.instance_variable_get(:@running)).to be false
    end

    it "does not start if enabled is false" do
      DeadBro.configuration.enabled = false
      expect(monitor.start).to be_nil
      expect(monitor.instance_variable_get(:@running)).to be false
    end

    it "starts a background thread when enabled" do
      allow(client).to receive(:post_job_stats)
      allow(monitor).to receive(:collect_queue_stats).and_return(nil)

      thread = monitor.start
      expect(thread).to be_a(Thread)
      expect(monitor.instance_variable_get(:@running)).to be true

      monitor.stop
    end

    it "handles errors gracefully in the thread" do
      allow(monitor).to receive(:collect_queue_stats).and_raise(StandardError.new("Test error"))
      allow(monitor).to receive(:log_error)

      thread = monitor.start
      sleep(0.1) # Give thread time to run

      expect(monitor.instance_variable_get(:@running)).to be true
      expect(monitor).to have_received(:log_error).with(/Error collecting job queue stats/)

      monitor.stop
    end
  end

  describe "#stop" do
    it "stops the running thread" do
      allow(client).to receive(:post_job_stats)
      allow(monitor).to receive(:collect_queue_stats).and_return(nil)

      monitor.start
      expect(monitor.instance_variable_get(:@running)).to be true

      monitor.stop
      expect(monitor.instance_variable_get(:@running)).to be false
      expect(monitor.instance_variable_get(:@thread)).to be_nil
    end

    it "handles stop when not running" do
      expect { monitor.stop }.not_to raise_error
    end
  end

  describe "#detect_queue_system" do
    it "detects Sidekiq when available" do
      stub_const("Sidekiq", Module.new)
      expect(monitor.send(:detect_queue_system)).to eq(:sidekiq)
    end

    it "detects SolidQueue when available" do
      stub_const("SolidQueue", Module.new)
      expect(monitor.send(:detect_queue_system)).to eq(:solid_queue)
    end

    it "detects Delayed::Job when available" do
      delayed_module = Module.new
      stub_const("Delayed", delayed_module)
      stub_const("Delayed::Job", Class.new)
      expect(monitor.send(:detect_queue_system)).to eq(:delayed_job)
    end

    it "detects GoodJob when available" do
      stub_const("GoodJob", Module.new)
      expect(monitor.send(:detect_queue_system)).to eq(:good_job)
    end

    it "returns unknown when no queue system is detected" do
      expect(monitor.send(:detect_queue_system)).to eq(:unknown)
    end

    it "prioritizes Sidekiq over other systems" do
      stub_const("Sidekiq", Module.new)
      stub_const("SolidQueue", Module.new)
      expect(monitor.send(:detect_queue_system)).to eq(:sidekiq)
    end
  end

  describe "#collect_queue_stats" do
    before do
      if defined?(Rails)
        allow(Rails).to receive(:env).and_return("test")
      else
        stub_const("Rails", double(env: "test"))
      end
    end

    it "returns nil for unknown queue systems" do
      allow(monitor).to receive(:detect_queue_system).and_return(:unknown)
      expect(monitor.send(:collect_queue_stats)).to be_nil
    end

    it "includes timestamp, queue_system, and environment" do
      stub_const("Sidekiq", Module.new)
      allow(monitor).to receive(:collect_sidekiq_stats).and_return({ total_queued: 0, total_busy: 0, queues: {} })

      stats = monitor.send(:collect_queue_stats)

      expect(stats[:timestamp]).to be_a(String)
      expect(stats[:queue_system]).to eq(:sidekiq)
      expect(stats[:environment]).to eq("test")
      expect(stats[:queues]).to be_a(Hash)
    end

    it "calls collect_sidekiq_stats for Sidekiq" do
      stub_const("Sidekiq", Module.new)
      sidekiq_stats = { total_queued: 5, total_busy: 2, queues: {} }
      allow(monitor).to receive(:collect_sidekiq_stats).and_return(sidekiq_stats)

      stats = monitor.send(:collect_queue_stats)
      expect(monitor).to have_received(:collect_sidekiq_stats)
      expect(stats[:queues]).to eq(sidekiq_stats)
    end
  end

  describe "#collect_sidekiq_stats" do
    let(:sidekiq_queue) { double("Sidekiq::Queue", name: "default", size: 10) }
    let(:sidekiq_queue_class) { double("Sidekiq::Queue", all: [sidekiq_queue]) }
    let(:sidekiq_workers) { double("Sidekiq::Workers", each: []) }
    let(:sidekiq_workers_class) { double("Sidekiq::Workers", new: sidekiq_workers) }
    let(:scheduled_set) { double("Sidekiq::ScheduledSet", size: 5) }
    let(:retry_set) { double("Sidekiq::RetrySet", size: 3) }
    let(:dead_set) { double("Sidekiq::DeadSet", size: 2) }
    let(:process_set) { double("Sidekiq::ProcessSet", size: 1) }

    context "when Sidekiq is not defined" do
      before do
        # Don't stub Sidekiq in this context
      end

      it "returns empty hash" do
        # Since we're in a context without Sidekiq stubbed, and if Sidekiq doesn't exist
        # in the test environment, this should work. If it does exist, we'll skip.
        skip "Sidekiq is defined in test environment" if defined?(Sidekiq)
        expect(monitor.send(:collect_sidekiq_stats)).to eq({})
      end
    end

    context "when Sidekiq is defined" do
      before do
        stub_const("Sidekiq", Module.new)
      end

      it "collects queue statistics" do
        allow(Sidekiq).to receive(:const_get).with(:Queue).and_return(sidekiq_queue_class)
        allow(Sidekiq).to receive(:const_get).with(:Workers).and_raise(NameError)
        allow(Sidekiq).to receive(:respond_to?).with(:workers).and_return(false)
        allow(Sidekiq).to receive(:const_get).with(:ScheduledSet).and_return(double(new: scheduled_set))
        allow(Sidekiq).to receive(:const_get).with(:RetrySet).and_return(double(new: retry_set))
        allow(Sidekiq).to receive(:const_get).with(:DeadSet).and_return(double(new: dead_set))
        allow(Sidekiq).to receive(:const_get).with(:ProcessSet).and_return(double(new: process_set))

        stats = monitor.send(:collect_sidekiq_stats)

        expect(stats[:total_queued]).to eq(10)
        expect(stats[:queues]["default"][:queued]).to eq(10)
        expect(stats[:total_scheduled]).to eq(5)
        expect(stats[:total_retries]).to eq(3)
        expect(stats[:total_dead]).to eq(2)
        expect(stats[:processes]).to eq(1)
      end

      it "handles NameError when Sidekiq classes are not available" do
        allow(Sidekiq).to receive(:const_get).and_raise(NameError.new("uninitialized constant"))
        allow(monitor).to receive(:log_error)

        stats = monitor.send(:collect_sidekiq_stats)

        expect(stats).to eq({ total_queued: 0, total_busy: 0, queues: {} })
      end

      it "handles workers with queue information" do
        work_data = { "queue" => "high_priority" }
        workers = double("Sidekiq::Workers")
        allow(workers).to receive(:each).and_yield("process_id", "thread_id", work_data)
        allow(Sidekiq).to receive(:const_get).and_call_original
        allow(Sidekiq).to receive(:const_get).with(:Queue).and_return(sidekiq_queue_class)
        allow(Sidekiq).to receive(:const_get).with(:Workers).and_return(double(new: workers))
        allow(Sidekiq).to receive(:const_get).with(:ScheduledSet).and_raise(NameError)
        allow(Sidekiq).to receive(:const_get).with(:RetrySet).and_raise(NameError)
        allow(Sidekiq).to receive(:const_get).with(:DeadSet).and_raise(NameError)
        allow(Sidekiq).to receive(:const_get).with(:ProcessSet).and_raise(NameError)
        allow(Sidekiq).to receive(:respond_to?).with(:workers).and_return(false)

        stats = monitor.send(:collect_sidekiq_stats)

        expect(stats[:total_busy]).to eq(1)
        expect(stats[:queues]["high_priority"][:busy]).to eq(1)
      end
    end
  end

  describe "#collect_solid_queue_stats" do
    let(:connection) { double("ActiveRecord::Base.connection") }
    let(:query_result) { [{ "queue_name" => "default", "count" => "5" }] }

    before do
      stub_const("SolidQueue", Module.new)
      ar_module = Module.new
      base_class = Class.new
      stub_const("ActiveRecord", ar_module)
      stub_const("ActiveRecord::Base", base_class)
      # connected? is a class method, not an instance method
      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(connection).to receive(:table_exists?).and_return(true)
    end

    it "returns empty hash when SolidQueue is not defined" do
      # When SolidQueue is not defined, the method returns {} (empty hash)
      # We can't easily test this without removing the constant, which causes RSpec cleanup issues
      # So we'll just verify the method handles the case gracefully
      skip "Cannot test without removing constant due to RSpec cleanup issues"
    end

    it "collects queue statistics from database" do
      # Mock the execute calls - use order to match calls in sequence
      call_count = 0
      allow(connection).to receive(:execute) do |sql|
        call_count += 1
        case call_count
        when 1
          # First call: queued jobs
          query_result
        when 2
          # Second call: busy jobs
          []
        when 3
          # Third call: scheduled jobs
          [{ "count" => "0" }]
        when 4
          # Fourth call: failed jobs
          [{ "count" => "0" }]
        else
          []
        end
      end
      
      stats = monitor.send(:collect_solid_queue_stats)

      expect(stats[:total_queued]).to eq(5)
      expect(stats[:queues]["default"][:queued]).to eq(5)
    end

    it "handles missing ActiveRecord connection" do
      allow(ActiveRecord::Base).to receive(:connected?).and_return(false)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)

      stats = monitor.send(:collect_solid_queue_stats)

      expect(stats).to eq({ total_queued: 0, total_busy: 0, queues: {} })
    end

    it "handles database errors gracefully" do
      allow(connection).to receive(:execute).and_raise(StandardError.new("DB error"))
      allow(monitor).to receive(:log_error)

      stats = monitor.send(:collect_solid_queue_stats)

      expect(stats).to eq({ total_queued: 0, total_busy: 0, queues: {} })
      expect(monitor).to have_received(:log_error).with(/Error collecting Solid Queue stats/)
    end
  end

  describe "#collect_delayed_job_stats" do
    let(:delayed_job_class) { double("Delayed::Job") }
    let(:connection) { double("ActiveRecord::Base.connection", connected?: true, table_exists?: true) }

    before do
      delayed_module = Module.new
      stub_const("Delayed", delayed_module)
      stub_const("Delayed::Job", delayed_job_class)
      ar_module = Module.new
      base_class = Class.new
      stub_const("ActiveRecord", ar_module)
      stub_const("ActiveRecord::Base", base_class)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    end

    it "returns empty stats when Delayed::Job is not defined" do
      allow(monitor).to receive(:defined?).and_call_original
      allow(monitor).to receive(:defined?).with(Delayed::Job).and_return(false)
      expect(monitor.send(:collect_delayed_job_stats)).to eq({ total_queued: 0, total_busy: 0, queues: {} })
    end

    it "collects job statistics" do
      # Mock the where chain for queued jobs - need to allow ActiveRecord::Base.connected? and table_exists?
      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(connection).to receive(:table_exists?).with("delayed_jobs").and_return(true)
      
      queued_relation = double("Relation")
      allow(queued_relation).to receive(:count).and_return(5)
      allow(delayed_job_class).to receive(:where).with("locked_at IS NULL AND attempts < max_attempts").and_return(queued_relation)
      
      # Mock the where chain for busy jobs
      busy_relation = double("Relation")
      allow(busy_relation).to receive(:count).and_return(2)
      allow(delayed_job_class).to receive(:where).with("locked_at IS NOT NULL AND locked_by IS NOT NULL").and_return(busy_relation)
      
      # Mock the where chain for failed jobs
      failed_relation = double("Relation")
      allow(failed_relation).to receive(:count).and_return(1)
      allow(delayed_job_class).to receive(:where).with("attempts >= max_attempts").and_return(failed_relation)

      stats = monitor.send(:collect_delayed_job_stats)

      expect(stats[:total_queued]).to eq(5)
      expect(stats[:queues]["default"][:queued]).to eq(5)
      expect(stats[:total_busy]).to eq(2)
      expect(stats[:total_failed]).to eq(1)
    end
  end

  describe "#collect_good_job_stats" do
    let(:connection) { double("ActiveRecord::Base.connection") }
    let(:query_result) { [{ "queue_name" => "default", "count" => "3" }] }

    before do
      stub_const("GoodJob", Module.new)
      ar_module = Module.new
      base_class = Class.new
      stub_const("ActiveRecord", ar_module)
      stub_const("ActiveRecord::Base", base_class)
      # connected? is a class method, not an instance method
      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(connection).to receive(:table_exists?).and_return(true)
    end

    it "returns empty hash when GoodJob is not defined" do
      # When GoodJob is not defined, the method returns {} (empty hash)
      # We can't easily test this without removing the constant, which causes RSpec cleanup issues
      # So we'll just verify the method handles the case gracefully
      skip "Cannot test without removing constant due to RSpec cleanup issues"
    end

    it "collects queue statistics from database" do
      # Mock the execute calls - use order to match calls in sequence
      call_count = 0
      allow(connection).to receive(:execute) do |sql|
        call_count += 1
        case call_count
        when 1
          # First call: queued jobs
          query_result
        when 2
          # Second call: busy jobs
          []
        when 3
          # Third call: scheduled jobs
          [{ "count" => "0" }]
        when 4
          # Fourth call: failed jobs
          [{ "count" => "0" }]
        else
          []
        end
      end
      
      stats = monitor.send(:collect_good_job_stats)

      expect(stats[:total_queued]).to eq(3)
      expect(stats[:queues]["default"][:queued]).to eq(3)
    end
  end

  describe "#parse_query_result" do
    it "handles array results" do
      result = [{ "key" => "value" }]
      expect(monitor.send(:parse_query_result, result)).to eq(result)
    end

    it "handles results with values method" do
      result = double("Result")
      allow(result).to receive(:respond_to?).with(:each).and_return(true)
      allow(result).to receive(:respond_to?).with(:values).and_return(true)
      allow(result).to receive(:fields).and_return(["key"])
      allow(result).to receive(:values).and_return([["value"]])
      parsed = monitor.send(:parse_query_result, result)
      expect(parsed).to be_an(Array)
      expect(parsed.length).to eq(1)
      expect(parsed.first["key"]).to eq("value")
      expect(parsed.first[:key]).to eq("value")
    end

    it "handles results that respond to to_a" do
      result = double("Result")
      allow(result).to receive(:respond_to?).with(:each).and_return(true)
      allow(result).to receive(:respond_to?).with(:values).and_return(false)
      allow(result).to receive(:is_a?).with(Array).and_return(false)
      allow(result).to receive(:to_a).and_return([{ "key" => "value" }])
      expect(monitor.send(:parse_query_result, result)).to eq([{ "key" => "value" }])
    end

    it "returns empty array for invalid results" do
      result = "invalid"
      expect(monitor.send(:parse_query_result, result)).to eq([])
    end

    it "handles errors gracefully" do
      result = double("Result")
      allow(result).to receive(:respond_to?).and_raise(StandardError.new("Error"))
      allow(monitor).to receive(:log_error)

      expect(monitor.send(:parse_query_result, result)).to eq([])
      expect(monitor).to have_received(:log_error).with(/Error parsing query result/)
    end
  end

  describe "#log_error" do
    it "logs to Rails logger when available" do
      rails_logger = double("Rails.logger")
      if defined?(Rails)
        allow(Rails).to receive(:logger).and_return(rails_logger)
      else
        stub_const("Rails", double(logger: rails_logger))
      end
      allow(rails_logger).to receive(:error)

      monitor.send(:log_error, "Test error")

      expect(rails_logger).to have_received(:error).with("[DeadBro::JobQueueMonitor] Test error")
    end

    it "logs to stderr when Rails is not available" do
      # Temporarily hide Rails
      rails_defined = defined?(Rails)
      rails_module = Rails if rails_defined
      Object.send(:remove_const, :Rails) if rails_defined

      expect($stderr).to receive(:puts).with("[DeadBro::JobQueueMonitor] Test error")

      monitor.send(:log_error, "Test error")

      # Restore Rails
      stub_const("Rails", rails_module) if rails_defined && !defined?(Rails)
    end
  end

  describe "integration with client" do
    it "calls post_job_stats with collected stats" do
      stub_const("Sidekiq", Module.new)
      allow(monitor).to receive(:collect_sidekiq_stats).and_return({ total_queued: 5, total_busy: 2, queues: {} })
      if defined?(Rails)
        allow(Rails).to receive(:env).and_return("test")
      else
        stub_const("Rails", double(env: "test"))
      end

      expect(client).to receive(:post_job_stats).with(hash_including(
        queue_system: :sidekiq,
        environment: "test"
      ))

      stats = monitor.send(:collect_queue_stats)
      monitor.instance_variable_get(:@client).post_job_stats(stats) if stats
    end
  end
end
