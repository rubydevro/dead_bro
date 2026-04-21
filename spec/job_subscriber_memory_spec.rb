# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::JobSubscriber, "memory tracking fallback" do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    DeadBro.configuration.memory_tracking_enabled = true

    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    ActiveSupport::Notifications.unsubscribe("exception.active_job")

    # Ensure no SQL tracking is active (forces the fallback path)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
  end

  after do
    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    ActiveSupport::Notifications.unsubscribe("exception.active_job")
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
  end

  let(:captured_payloads) { [] }

  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
    allow(client).to receive(:post_heartbeat)
    client
  end

  let(:mock_job_class) do
    klass = double("JobClass")
    allow(klass).to receive(:name).and_return("TestJob")
    klass
  end

  let(:mock_job) do
    job = double("Job")
    allow(job).to receive(:class).and_return(mock_job_class)
    allow(job).to receive(:job_id).and_return("abc-123")
    allow(job).to receive(:queue_name).and_return("default")
    allow(job).to receive(:arguments).and_return([])
    job
  end

  it "populates memory_events[:memory_before] when perform_start did not fire" do
    described_class.subscribe!(client: stub_client)

    # Fire perform.active_job without a preceding perform_start.active_job.
    # SqlSubscriber.tracking_active? returns false → fallback path runs.
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job})

    expect(captured_payloads).not_to be_empty
    memory_events = captured_payloads.first[:payload][:memory_events]
    # memory_before should be a number, not nil — tracking must have been started
    expect(memory_events[:memory_before]).not_to be_nil
    expect(memory_events[:memory_before]).to be_a(Numeric)
  end

  it "populates memory_events[:memory_before] for exception jobs when perform_start did not fire" do
    described_class.subscribe!(client: stub_client)

    exception = StandardError.new("boom")
    exception.set_backtrace(["line1"])

    ActiveSupport::Notifications.instrument("exception.active_job", {job: mock_job, exception_object: exception})

    expect(captured_payloads).not_to be_empty
    memory_events = captured_payloads.first[:payload][:memory_events]
    expect(memory_events[:memory_before]).not_to be_nil
    expect(memory_events[:memory_before]).to be_a(Numeric)
  end
end
