# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::SidekiqServerMiddleware do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    allow(DeadBro).to receive(:client).and_return(stub_client)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
  end

  after do
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
  end

  let(:captured_payloads) { [] }

  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
    client
  end

  let(:middleware) { described_class.new }

  # A job hash as Sidekiq hands it to server middleware.
  def native_job(overrides = {})
    {"class" => "HardWorker", "jid" => "b4a577edbccf1d805744efa9", "queue" => "critical",
     "args" => [1, "two"], "enqueued_at" => Time.now.to_f - 2.5}.merge(overrides)
  end

  def payload = captured_payloads.last[:payload]

  it "reports a native Sidekiq job's run" do
    result = middleware.call(Object.new, native_job, "critical") { :done }

    expect(result).to eq(:done)
    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.last[:event_name]).to eq("perform.sidekiq")
    expect(payload).to include(
      job_class: "HardWorker", job_id: "b4a577edbccf1d805744efa9", queue_name: "critical",
      arguments: ["1", "two"], status: "completed"
    )
    expect(payload[:queue_duration_ms]).to be_within(500).of(2500)
  end

  it "arms SQL and dependency tracking for the run, which perform_start.active_job would have" do
    tracking = nil
    middleware.call(Object.new, native_job, "critical") { tracking = DeadBro::SqlSubscriber.tracking_active? }

    expect(tracking).to be true
    expect(DeadBro::SqlSubscriber.tracking_active?).to be false
  end

  it "reports a raising run as failed and re-raises the job's own exception" do
    boom = KeyError.new("missing")
    boom.set_backtrace(["app/workers/hard_worker.rb:4:in `perform'"])

    expect { middleware.call(Object.new, native_job, "critical") { raise boom } }
      .to raise_error { |raised| expect(raised).to equal(boom) }
    expect(payload).to include(status: "failed", error: true, exception_class: "KeyError", message: "missing")
    expect(captured_payloads.last[:force]).to be true
  end

  # Sidekiq 8 sends epoch milliseconds; earlier versions float seconds.
  it "reads enqueued_at in integer milliseconds as well" do
    middleware.call(Object.new, native_job("enqueued_at" => ((Time.now.to_f - 4) * 1000).to_i), "critical") {}

    expect(payload[:queue_duration_ms]).to be_within(1000).of(4000)
  end

  # ActiveJob jobs that Sidekiq runs are reported by JobSubscriber.
  it "leaves wrapped ActiveJob jobs alone" do
    job = native_job("class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "ImportJob")

    expect(middleware.call(Object.new, job, "default") { :ran }).to eq(:ran)
    expect(captured_payloads).to be_empty
  end

  it "does no work while DeadBro is disabled" do
    DeadBro.configuration.enabled = false
    expect(DeadBro::JobSubscriber).not_to receive(:start_job_tracking)

    expect(middleware.call(Object.new, native_job, "critical") { :ran }).to eq(:ran)
    expect(captured_payloads).to be_empty
  end

  it "honours excluded_jobs" do
    DeadBro.configuration.excluded_jobs = ["HardWorker"]

    middleware.call(Object.new, native_job, "critical") {}

    expect(captured_payloads).to be_empty
  end

  it "never lets its own failure reach the job, nor replace the job's exception" do
    allow(stub_client).to receive(:post_metric).and_raise(StandardError, "transport down")

    expect(middleware.call(Object.new, native_job, "critical") { :ok }).to eq(:ok)
    expect { middleware.call(Object.new, native_job, "critical") { raise ArgumentError, "job's own" } }
      .to raise_error(ArgumentError, "job's own")
  end

  describe ".install!" do
    it "adds itself to the server middleware chain" do
      chain = double("Chain")
      expect(chain).to receive(:add).with(described_class)
      config = double("Config")
      allow(config).to receive(:server_middleware).and_yield(chain)
      sidekiq = Module.new
      sidekiq.define_singleton_method(:configure_server) { |&block| block.call(config) }
      stub_const("Sidekiq", sidekiq)

      described_class.install!
    end

    it "does nothing without Sidekiq" do
      hide_const("Sidekiq") if defined?(::Sidekiq)

      expect { described_class.install! }.not_to raise_error
    end
  end
end
