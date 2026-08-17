# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::JobSubscriber, "per-job-type sampling" do
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

  it "samples out a job type whose override is 0, even with global sample_rate 100" do
    DeadBro.configuration.sample_rate = 100
    DeadBro.configuration.sample_rates_by_type = {"TestJob#perform" => 0}

    described_class.subscribe!(client: stub_client)
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job})

    expect(captured_payloads).to be_empty
  end

  it "keeps sampling a job type whose override is 100, even with global sample_rate 0" do
    DeadBro.configuration.sample_rate = 0
    DeadBro.configuration.sample_rates_by_type = {"TestJob#perform" => 100}

    described_class.subscribe!(client: stub_client)
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job})

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.first[:force]).to be true
  end
end
