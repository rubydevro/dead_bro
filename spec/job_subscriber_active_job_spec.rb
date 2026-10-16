# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_job"

# job_subscriber_handled_error_spec replays ActiveJob's events by hand; these run
# real jobs on ActiveJob's test adapter. A Rails release that moved
# enqueue_retry / retry_stopped / discard out of perform_now, renamed them or
# changed their payload would fail here.
RSpec.describe DeadBro::JobSubscriber, "with real ActiveJob jobs" do
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
    DeadBro::JobSqlTrackingMiddleware.subscribe!
    described_class.subscribe!(client: stub_client)

    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.logger = Logger.new(nil)
    stub_const("InvoiceSyncError", Class.new(StandardError))
  end

  after do
    subscribed_events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    Thread.current[DeadBro::JobSubscriber::HANDLED_ERRORS_KEY] = nil
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
  end

  let(:payloads) { [] }

  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| payloads << kwargs[:payload] }
    client
  end

  # InvoiceSyncJob, raising InvoiceSyncError on its first `failures` attempts.
  # The block declares how the job handles that (retry_on, discard_on).
  def define_job(failures: Float::INFINITY, &handling)
    job_class = Class.new(ActiveJob::Base) do
      class_eval(&handling) if handling
      define_method(:perform) { raise InvoiceSyncError, "attempt #{executions}" if executions <= failures }
    end
    stub_const("InvoiceSyncJob", job_class)
  end

  # Runs the retry retry_on enqueued, the way a queue adapter would.
  def run_enqueued_retry
    ActiveJob::Base.execute(ActiveJob::Base.queue_adapter.enqueued_jobs.pop)
  end

  it "reports an attempt retry_on retried as failed, and the retry that completes as completed" do
    define_job(failures: 1) { retry_on InvoiceSyncError, wait: 0, attempts: 3 }

    InvoiceSyncJob.perform_now
    expect(payloads.last).to include(
      job_class: "InvoiceSyncJob", status: "failed", error: true,
      exception_class: "InvoiceSyncError", message: "attempt 1", error_handling: "retried"
    )

    run_enqueued_retry
    expect(payloads.size).to eq(2)
    expect(payloads.last).to include(job_class: "InvoiceSyncJob", status: "completed")
    expect(payloads.last).not_to have_key(:error_handling)
  end

  it "labels the last attempt retries_exhausted when retry_on lets its exception escape" do
    define_job { retry_on InvoiceSyncError, wait: 0, attempts: 2 }

    InvoiceSyncJob.perform_now
    expect { run_enqueued_retry }.to raise_error(InvoiceSyncError, "attempt 2")

    expect(payloads.map { |payload| payload[:error_handling] }).to eq(%w[retried retries_exhausted])
    expect(payloads.last).to include(status: "failed", message: "attempt 2")
  end

  it "reports retries that ran out into retry_on's block as failed" do
    define_job { retry_on(InvoiceSyncError, wait: 0, attempts: 1) { |_job, _error| } }

    expect { InvoiceSyncJob.perform_now }.not_to raise_error
    expect(payloads.last).to include(status: "failed", error_handling: "retries_exhausted")
  end

  it "reports a run discard_on discarded as failed" do
    define_job { discard_on InvoiceSyncError }

    expect { InvoiceSyncJob.perform_now }.not_to raise_error
    expect(payloads.last).to include(status: "failed", exception_class: "InvoiceSyncError", error_handling: "discarded")
  end

  it "reports a run that raised nothing as completed" do
    define_job(failures: 0)

    InvoiceSyncJob.perform_now
    expect(payloads.last).to include(job_class: "InvoiceSyncJob", status: "completed")
    expect(payloads.last).not_to have_key(:error)
  end

  # Sidekiq raises Sidekiq::Shutdown into jobs still running when its shutdown
  # times out, and runs them again after the restart.
  it "reports nothing for a run Sidekiq cut short to shut down" do
    stub_const("Sidekiq::Shutdown", Class.new(Interrupt))
    stub_const("InvoiceSyncJob", Class.new(ActiveJob::Base) { def perform = raise(Sidekiq::Shutdown) })

    expect { InvoiceSyncJob.perform_now }.to raise_error(Sidekiq::Shutdown)
    expect(payloads).to be_empty
    expect(DeadBro::SqlSubscriber.tracking_active?).to be false
  end
end
