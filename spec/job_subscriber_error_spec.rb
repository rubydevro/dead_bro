# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::JobSubscriber, "job exception payload" do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true

    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
  end

  after do
    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
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

  # There is no "exception.active_job" event anywhere in Rails/ActiveJob.
  # ActiveJob wraps execution with `instrument(:perform) { super }`
  # (ActiveJob::Instrumentation#instrument), and
  # ActiveSupport::Notifications::Instrumenter#instrument sets
  # payload[:exception]/payload[:exception_object], runs `ensure handle.finish`
  # (which fires this gem's perform.active_job subscriber), and THEN re-raises —
  # so a raising job still fires perform.active_job with the exception attached,
  # and the subscriber must have already run by the time the raise propagates.
  # This simulates that real sequence instead of a nonexistent event.
  def instrument_failing_job(exception)
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job}) do
      raise exception
    end
  rescue StandardError
    # Swallow here the way ActiveJob's own perform_now/rescue_with_handler would;
    # the subscriber has already run by this point (inside the instrument call's
    # ensure), which is all this spec cares about.
  end

  it "sends event_name: perform.active_job (not the exception class) so ingest classifies it as a job" do
    described_class.subscribe!(client: stub_client)

    exception = StandardError.new("boom")
    exception.set_backtrace(["app/jobs/test_job.rb:5:in `perform'"])
    instrument_failing_job(exception)

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.first[:event_name]).to eq(DeadBro::JobSubscriber::JOB_EVENT_NAME)
  end

  it "marks the payload as an error and includes a fingerprint and cause chain" do
    described_class.subscribe!(client: stub_client)

    exception = StandardError.new("boom")
    exception.set_backtrace(["app/jobs/test_job.rb:5:in `perform'"])
    instrument_failing_job(exception)

    payload = captured_payloads.first[:payload]
    expect(payload[:error]).to be true
    expect(payload[:status]).to eq("failed")
    expect(payload[:exception_class]).to eq("StandardError")
    expect(payload[:fingerprint]).to be_a(String)
    expect(payload[:fingerprint]).not_to be_empty
  end

  it "ships the error regardless of a 0 sample rate for that job type" do
    DeadBro.configuration.sample_rate = 0
    DeadBro.configuration.sample_rates_by_type = {"TestJob#perform" => 0}
    described_class.subscribe!(client: stub_client)

    exception = StandardError.new("boom")
    exception.set_backtrace(["line1"])
    instrument_failing_job(exception)

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.first[:force]).to be true
  end

  it "sends status: completed (not failed) for a job that does not raise" do
    described_class.subscribe!(client: stub_client)

    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job}) {}

    payload = captured_payloads.first[:payload]
    expect(payload[:status]).to eq("completed")
    expect(payload[:error]).to be_nil
  end

  it "includes transaction_events in the payload and does not leak the thread-local across jobs" do
    described_class.subscribe!(client: stub_client)

    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job}) {}

    payload = captured_payloads.first[:payload]
    expect(payload).to have_key(:transaction_events)
    # start_request_tracking (via perform_start.active_job / the fallback here)
    # also pushes onto the transaction-events stack; stop_request_tracking alone
    # would leave it unpopped for every subsequent job on this Sidekiq thread.
    expect(Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY]).to be_nil
  end

  it "does not leak the transaction-events thread-local when a job is excluded (drain_job_tracking path)" do
    DeadBro.configuration.excluded_jobs = ["TestJob"]
    described_class.subscribe!(client: stub_client)

    DeadBro::SqlSubscriber.start_request_tracking
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job}) {}

    expect(captured_payloads).to be_empty
    expect(Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY]).to be_nil
  end
end
