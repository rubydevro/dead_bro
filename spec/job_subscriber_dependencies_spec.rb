# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::JobSubscriber, "dependency capture inside jobs" do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    DeadBro.configuration.sample_rate = 100

    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    ActiveSupport::Notifications.unsubscribe("perform_start.active_job")
    ActiveSupport::Notifications.unsubscribe("exception.active_job")
    clear_thread_locals
  end

  after do
    ActiveSupport::Notifications.unsubscribe("perform.active_job")
    ActiveSupport::Notifications.unsubscribe("perform_start.active_job")
    ActiveSupport::Notifications.unsubscribe("exception.active_job")
    clear_thread_locals
  end

  def clear_thread_locals
    Thread.current[:dead_bro_http_events] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::RedisSubscriber::THREAD_LOCAL_KEY] = nil if defined?(DeadBro::RedisSubscriber)
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
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

  it "initializes the http-events thread-local when the job starts" do
    DeadBro::JobSqlTrackingMiddleware.subscribe!

    ActiveSupport::Notifications.instrument("perform_start.active_job", {job: mock_job})

    expect(Thread.current[:dead_bro_http_events]).to eq([])
  end

  it "includes outbound HTTP calls made during the job in the payload" do
    DeadBro::JobSqlTrackingMiddleware.subscribe!
    described_class.subscribe!(client: stub_client)

    ActiveSupport::Notifications.instrument("perform_start.active_job", {job: mock_job})
    # Simulate an HTTP call recorded by HttpInstrumentation during the job body.
    Thread.current[:dead_bro_http_events] << {"method" => "GET", "host" => "api.example.com", "duration_ms" => 42.0}
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job})

    expect(captured_payloads.size).to eq(1)
    http = captured_payloads.first[:payload][:http_outgoing]
    expect(http).to be_an(Array)
    expect(http.first["host"]).to eq("api.example.com")
    expect(http.first["duration_ms"]).to eq(42.0)
  end

  it "clears the http-events thread-local after sending, so a later job on the same thread starts clean" do
    DeadBro::JobSqlTrackingMiddleware.subscribe!
    described_class.subscribe!(client: stub_client)

    ActiveSupport::Notifications.instrument("perform_start.active_job", {job: mock_job})
    Thread.current[:dead_bro_http_events] << {"method" => "GET", "host" => "api.example.com", "duration_ms" => 42.0}
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job})

    expect(Thread.current[:dead_bro_http_events]).to be_nil
  end

  it "sends empty dependency arrays for a job that touches no external services" do
    DeadBro::JobSqlTrackingMiddleware.subscribe!
    described_class.subscribe!(client: stub_client)

    ActiveSupport::Notifications.instrument("perform_start.active_job", {job: mock_job})
    ActiveSupport::Notifications.instrument("perform.active_job", {job: mock_job})

    payload = captured_payloads.first[:payload]
    expect(payload[:http_outgoing]).to eq([])
    expect(payload[:redis_events]).to eq([])
    expect(payload).to have_key(:view_events)
  end
end
