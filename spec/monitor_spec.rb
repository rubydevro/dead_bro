# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Monitor do
  let(:client) { instance_double(DeadBro::Client) }
  let(:monitor) { described_class.new(client: client) }

  before do
    # Reset configuration
    DeadBro.reset_configuration!
    DeadBro.configuration.monitor_enabled = true
    DeadBro.configuration.enabled = true
    DeadBro.configuration.api_key = "test-api-key"
    allow(client).to receive(:post_heartbeat)
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
    it "does not start if already running with a live thread" do
      allow(monitor).to receive(:collect_and_send_stats)
      monitor.start
      first_thread = monitor.instance_variable_get(:@thread)

      # Call start again while thread is alive — must be a no-op
      result = monitor.start
      expect(result).to be_nil
      expect(monitor.instance_variable_get(:@thread)).to equal(first_thread)

      monitor.stop
    end

    it "restarts after a dead thread (post-fork scenario)" do
      allow(monitor).to receive(:collect_and_send_stats)
      monitor.start

      # Simulate fork: @running=true but thread is dead
      monitor.instance_variable_get(:@thread).kill.join
      expect(monitor.instance_variable_get(:@thread).alive?).to be false

      # start must detect dead thread and spawn a new one
      new_thread = monitor.start
      expect(new_thread).to be_a(Thread)
      expect(new_thread.alive?).to be true

      monitor.stop
    end

    it "starts even when monitor_enabled is false" do
      DeadBro.configuration.monitor_enabled = false
      allow(monitor).to receive(:collect_and_send_stats)

      thread = monitor.start
      expect(thread).to be_a(Thread)
      expect(monitor.instance_variable_get(:@running)).to be true

      monitor.stop
    end

    it "does not start if enabled is false" do
      DeadBro.configuration.enabled = false
      expect(monitor.start).to be_nil
      expect(monitor.instance_variable_get(:@running)).to be false
    end

    it "starts a background thread when enabled" do
      allow(client).to receive(:post_monitor_stats)
      allow(monitor).to receive(:collect_and_send_stats)

      thread = monitor.start
      expect(thread).to be_a(Thread)
      expect(monitor.instance_variable_get(:@running)).to be true

      monitor.stop
    end

    it "handles errors gracefully in the thread" do
      allow(monitor).to receive(:collect_and_send_stats).and_raise(StandardError.new("Test error"))
      allow(monitor).to receive(:log_error)

      monitor.start
      sleep(0.1) # Give thread time to run

      expect(monitor.instance_variable_get(:@running)).to be true
      expect(monitor).to have_received(:log_error).with(/Error collecting stats/)

      monitor.stop
    end
  end

  describe "#stop" do
    it "stops the running thread" do
      allow(client).to receive(:post_monitor_stats)
      allow(monitor).to receive(:collect_and_send_stats)

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

      expect(rails_logger).to have_received(:error).with("[DeadBro::Monitor] Test error")
    end

    it "logs to stderr when Rails is not available" do
      # Temporarily hide Rails
      rails_defined = defined?(Rails)
      rails_module = Rails if rails_defined
      Object.send(:remove_const, :Rails) if rails_defined

      expect {
        monitor.send(:log_error, "Test error")
      }.to output("[DeadBro::Monitor] Test error\n").to_stderr

      # Restore Rails
      stub_const("Rails", rails_module) if rails_defined && !defined?(Rails)
    end
  end

  describe "integration with client" do
    it "calls post_monitor_stats with collected stats" do
      fake_jobs_payload = {queue_system: :sidekiq}
      fake_network_payload = {available: true}

      allow(DeadBro::Collectors::Jobs).to receive(:collect).and_return(fake_jobs_payload)
      allow(DeadBro::Collectors::Network).to receive(:collect).and_return(fake_network_payload)

      # Stub optional collectors if they are called (depending on default config)
      # Assuming default config might fail if not stubbed, or we can explicity enable them
      allow(DeadBro.configuration).to receive(:enable_db_stats).and_return(true)
      allow(DeadBro.configuration).to receive(:enable_process_stats).and_return(true)
      allow(DeadBro.configuration).to receive(:enable_system_stats).and_return(true)

      allow(DeadBro::Collectors::Database).to receive(:collect).and_return({db: "stats"})
      allow(DeadBro::Collectors::ProcessInfo).to receive(:collect).and_return({process: "stats"})
      allow(DeadBro::Collectors::System).to receive(:collect).and_return({system: "stats"})

      expect(client).to receive(:post_monitor_stats).with(hash_including(
        :environment,
        :host,
        :pid,
        :current_time,
        :jobs,
        :network,
        :db,
        :process,
        :system
      ))

      monitor.send(:collect_and_send_stats)
    end
  end
end
