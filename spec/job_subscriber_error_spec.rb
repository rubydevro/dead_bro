# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::JobSubscriber, "job exception payload" do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true

    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    ActiveSupport::Notifications.unsubscribe("exception.active_job")
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
    allow(job).to receive(:enqueued_at).and_return(nil)
    job
  end

  it "sends event_name: perform.active_job (not the exception class) so ingest classifies it as a job" do
    described_class.subscribe!(client: stub_client)

    exception = StandardError.new("boom")
    exception.set_backtrace(["app/jobs/test_job.rb:5:in `perform'"])
    ActiveSupport::Notifications.instrument("exception.active_job", {job: mock_job, exception_object: exception})

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.first[:event_name]).to eq(DeadBro::JobSubscriber::JOB_EVENT_NAME)
  end

  it "marks the payload as an error and includes a fingerprint and cause chain" do
    described_class.subscribe!(client: stub_client)

    exception = StandardError.new("boom")
    exception.set_backtrace(["app/jobs/test_job.rb:5:in `perform'"])
    ActiveSupport::Notifications.instrument("exception.active_job", {job: mock_job, exception_object: exception})

    payload = captured_payloads.first[:payload]
    expect(payload[:error]).to be true
    expect(payload[:status]).to eq("failed")
    expect(payload[:exception_class]).to eq("StandardError")
    expect(payload[:fingerprint]).to be_a(String)
    expect(payload[:fingerprint]).not_to be_empty
  end
end
