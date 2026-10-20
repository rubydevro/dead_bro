# frozen_string_literal: true

require "spec_helper"

# retry_on / discard_on rescue the exception inside ActiveJob's perform_now, so
# perform.active_job finishes without one. ActiveJob instruments
# enqueue_retry / retry_stopped / discard from inside that rescue — before
# perform.active_job finishes, on the same thread — which is what these specs
# replay with plain AS::Notifications (activejob isn't a dev dependency).
RSpec.describe DeadBro::JobSubscriber, "exceptions handled by retry_on / discard_on" do
  def subscribed_events
    ["perform_start.active_job", "perform.active_job", *DeadBro::JobSubscriber::HANDLED_ERROR_EVENTS.keys]
  end

  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    subscribed_events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    Thread.current[DeadBro::JobSubscriber::HANDLED_ERRORS_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
    described_class.subscribe!(client: stub_client)
  end

  after do
    subscribed_events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    Thread.current[DeadBro::JobSubscriber::HANDLED_ERRORS_KEY] = nil
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

  def fake_job(job_id = "job-1", class_name = "ImportJob")
    klass = double("JobClass", name: class_name)
    double("Job", class: klass, job_id: job_id, queue_name: "default", arguments: [42], enqueued_at: nil)
  end

  def error(klass = RuntimeError, message = "boom")
    klass.new(message).tap { |e| e.set_backtrace(["app/jobs/import_job.rb:7:in `perform'"]) }
  end

  # perform.active_job wrapping a handler that instruments `event` and swallows
  # the exception, as retry_on / discard_on do.
  def perform_handled(job, event, exception, extra = {})
    ActiveSupport::Notifications.instrument("perform.active_job", {job: job}) do
      ActiveSupport::Notifications.instrument(event, {job: job, error: exception}.merge(extra)) {}
    end
  end

  def payload = captured_payloads.last[:payload]

  it "reports a retried attempt as a failed run with the exception it raised" do
    perform_handled(fake_job, "enqueue_retry.active_job", error(Net::OpenTimeout, "execution expired"), wait: 3)

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.last[:event_name]).to eq("perform.active_job")
    expect(payload).to include(
      status: "failed", error: true, error_handling: "retried",
      exception_class: "Net::OpenTimeout", message: "execution expired", job_class: "ImportJob"
    )
    expect(payload[:fingerprint]).to be_a(String)
  end

  it "reports a discarded run as failed" do
    perform_handled(fake_job, "discard.active_job", error(ArgumentError))

    expect(payload).to include(status: "failed", error_handling: "discarded", exception_class: "ArgumentError")
  end

  it "reports retries exhausted into a block as failed" do
    perform_handled(fake_job, "retry_stopped.active_job", error)

    expect(payload).to include(status: "failed", error_handling: "retries_exhausted")
  end

  # Without a block, retry_on re-raises after retry_stopped, so the exception
  # reaches perform.active_job too.
  it "keeps the label when retries run out and the exception escapes" do
    exception = error
    begin
      ActiveSupport::Notifications.instrument("perform.active_job", {job: fake_job}) do
        ActiveSupport::Notifications.instrument("retry_stopped.active_job", {job: fake_job, error: exception}) {}
        raise exception
      end
    rescue RuntimeError
    end

    expect(captured_payloads.size).to eq(1)
    expect(payload).to include(status: "failed", error_handling: "retries_exhausted", exception_class: "RuntimeError")
  end

  it "ships a handled failure even when the job type samples at 0" do
    DeadBro.configuration.sample_rate = 0
    DeadBro.configuration.sample_rates_by_type = {"ImportJob#perform" => 0}

    perform_handled(fake_job, "enqueue_retry.active_job", error)

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.last[:force]).to be true
  end

  it "does not pin one job's handled exception on another job" do
    ActiveSupport::Notifications.instrument("perform.active_job", {job: fake_job("outer")}) do
      ActiveSupport::Notifications.instrument("enqueue_retry.active_job", {job: fake_job("other"), error: error}) {}
    end

    expect(payload).to include(status: "completed", job_id: "outer")
    expect(payload).not_to have_key(:error_handling)
  end

  it "forgets the handled exception once its run has been reported" do
    job = fake_job
    perform_handled(job, "enqueue_retry.active_job", error)
    ActiveSupport::Notifications.instrument("perform.active_job", {job: job}) {}

    expect(captured_payloads.map { |c| c[:payload][:status] }).to eq(%w[failed completed])
    expect(Thread.current[DeadBro::JobSubscriber::HANDLED_ERRORS_KEY]).to be_empty
  end

  # retry_job called outside perform leaves an entry no perform.active_job takes.
  it "drops a stale entry when the same job starts again" do
    job = fake_job
    ActiveSupport::Notifications.instrument("enqueue_retry.active_job", {job: job, error: error}) {}
    ActiveSupport::Notifications.instrument("perform_start.active_job", {job: job}) {}
    ActiveSupport::Notifications.instrument("perform.active_job", {job: job}) {}

    expect(payload[:status]).to eq("completed")
  end

  it "bounds the entries such stray events can leave behind" do
    (DeadBro::JobSubscriber::MAX_HANDLED_ERRORS + 5).times do |i|
      ActiveSupport::Notifications.instrument("enqueue_retry.active_job", {job: fake_job("stray-#{i}"), error: error}) {}
    end

    expect(Thread.current[DeadBro::JobSubscriber::HANDLED_ERRORS_KEY].size).to be <= DeadBro::JobSubscriber::MAX_HANDLED_ERRORS
  end

  it "ignores a retry enqueued without an exception" do
    ActiveSupport::Notifications.instrument("perform.active_job", {job: fake_job}) do
      ActiveSupport::Notifications.instrument("enqueue_retry.active_job", {job: fake_job, error: nil, wait: 5}) {}
    end

    expect(payload[:status]).to eq("completed")
  end
end
