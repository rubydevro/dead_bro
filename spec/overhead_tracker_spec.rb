# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::OverheadTracker do
  after do
    Thread.current[described_class::THREAD_KEY] = nil
  end

  # One String per iteration: the literal is frozen, + makes a copy.
  def allocate_strings(count)
    count.times { +"invoice" }
  end

  def measured_window(strings)
    overhead = described_class.enter
    allocate_strings(strings)
  ensure
    described_class.leave(overhead)
  end

  describe "windows" do
    it "adds up the time and allocations of every window, and nothing outside them" do
      described_class.start_request_tracking
      measured_window(100)
      allocate_strings(500)
      measured_window(100)

      payload = described_class.stamp({})

      expect(payload[:agent_allocated_objects]).to be_between(200, 230)
      expect(payload[:agent_overhead_ms]).to be_a(Float).and be > 0
    end

    it "counts a window opened inside an open one only once" do
      described_class.start_request_tracking
      outer = described_class.enter
      inner = described_class.enter
      allocate_strings(100)
      described_class.leave(inner)
      allocate_strings(100)
      described_class.leave(outer)

      expect(inner).to be_nil
      expect(described_class.stamp({})[:agent_allocated_objects]).to be_between(200, 230)
    end

    it "includes the window that is still open when the payload is stamped" do
      described_class.start_request_tracking
      overhead = described_class.enter
      allocate_strings(100)
      payload = described_class.stamp({})
      described_class.leave(overhead)

      expect(payload[:agent_allocated_objects]).to be_between(100, 130)
    end

    it "counts garbage collection that runs inside a window", if: GC.respond_to?(:total_time) do
      described_class.start_request_tracking
      gc_before = GC.total_time
      overhead = described_class.enter
      3.times { GC.start }
      described_class.leave(overhead)
      gc_ms = (GC.total_time - gc_before) / 1_000_000.0

      expect(gc_ms).to be > 0
      expect(described_class.stamp({})[:agent_overhead_ms]).to be > gc_ms / 2
    end

    it "leaves out another thread's time and objects, and the objects of the window it ran in",
      if: DeadBro::OverheadTracker::Meter::CPU_CLOCK == Process::CLOCK_THREAD_CPUTIME_ID do
      described_class.start_request_tracking
      other_ms = nil
      overhead = described_class.enter
      allocate_strings(100)
      Thread.new do
        started = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :nanosecond)
        allocate_strings(200_000)
        other_ms = (Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :nanosecond) - started) / 1_000_000.0
      end.join
      described_class.leave(overhead)
      measured_window(100)

      payload = described_class.stamp({})

      expect(payload[:agent_allocated_objects]).to be_between(100, 130)
      expect(payload[:agent_overhead_ms]).to be < other_ms / 2
    end

    it "does nothing on a thread that isn't tracking a request or job" do
      expect(described_class.enter).to be_nil
      expect { described_class.leave(nil) }.not_to raise_error
      expect(described_class.stamp({controller: "InvoicesController"})).to eq(controller: "InvoicesController")
    end
  end

  describe ".isolate" do
    it "costs the open window only the isolated stretch's objects when another thread runs in it",
      if: DeadBro::OverheadTracker::Meter::CPU_CLOCK == Process::CLOCK_THREAD_CPUTIME_ID do
      described_class.start_request_tracking
      overhead = described_class.enter
      allocate_strings(100)
      result = described_class.isolate do
        Thread.new { allocate_strings(200_000) }.join
        :joined
      end
      allocate_strings(100)
      described_class.leave(overhead)

      expect(result).to eq(:joined)
      expect(described_class.stamp({})[:agent_allocated_objects]).to be_between(200, 240)
    end

    it "just runs the block when no window is open" do
      expect(described_class.isolate { :rss }).to eq(:rss)

      described_class.start_request_tracking
      expect(described_class.isolate { :rss }).to eq(:rss)
      overhead = described_class.enter
      expect(overhead).to be_a(described_class::Meter)
      described_class.leave(overhead)
    end
  end

  describe ".start_request_tracking / .stop_request_tracking" do
    it "measures a job performed inline on its own and resumes the outer meter after it" do
      described_class.start_request_tracking
      request_meter = Thread.current[described_class::THREAD_KEY]
      measured_window(50)

      described_class.start_request_tracking
      measured_window(100)
      job_payload = described_class.stamp({})
      described_class.stop_request_tracking

      expect(job_payload[:agent_allocated_objects]).to be_between(100, 130)
      expect(Thread.current[described_class::THREAD_KEY]).to equal(request_meter)
      expect(described_class.stamp({})[:agent_allocated_objects]).to be_between(50, 80)

      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end
  end

  describe ".subscribe" do
    let(:event_name) { "dead_bro_overhead_spec.invoice_rendered" }

    after { ActiveSupport::Notifications.unsubscribe(event_name) }

    it "runs the listener inside a window, with the event's arguments" do
      received = nil
      described_class.subscribe(event_name) do |name, started, finished, _id, payload|
        received = [name, started.class, finished.class, payload[:invoice_id]]
        allocate_strings(100)
      end
      described_class.start_request_tracking

      ActiveSupport::Notifications.instrument(event_name, invoice_id: 42) {}

      expect(received).to eq([event_name, Time, Time, 42])
      expect(described_class.stamp({})[:agent_allocated_objects]).to be >= 100
    end

    it "closes the window when the listener raises" do
      described_class.subscribe(event_name) { |*| raise ArgumentError, "invoice total must be positive" }
      described_class.start_request_tracking

      expect { ActiveSupport::Notifications.instrument(event_name, invoice_id: 42) {} }.to raise_error(StandardError)

      overhead = described_class.enter
      expect(overhead).to be_a(described_class::Meter)
      described_class.leave(overhead)
    end
  end
end

RSpec.describe "DeadBro's own overhead on request and job samples" do
  let(:captured_payloads) { [] }
  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
    allow(client).to receive(:post_heartbeat)
    client
  end

  let(:job_class) { stub_const("SendReceiptJob", Struct.new(:job_id, :queue_name, :arguments, :enqueued_at)) }

  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    DeadBro.configuration.sample_rate = 100
    unsubscribe_all
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
    DeadBro::Subscriber.subscribe!(client: stub_client)
    DeadBro::SqlSubscriber.subscribe!
    DeadBro::JobSqlTrackingMiddleware.subscribe!
    DeadBro::JobSubscriber.subscribe!(client: stub_client)
  end

  after do
    unsubscribe_all
    Thread.current[DeadBro::OverheadTracker::THREAD_KEY] = nil
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
  end

  def unsubscribe_all
    [DeadBro::Subscriber::EVENT_NAME, DeadBro::SqlSubscriber::SQL_EVENT_NAME, "perform_start.active_job", DeadBro::JobSubscriber::JOB_EVENT_NAME].each do |name|
      ActiveSupport::Notifications.unsubscribe(name)
    end
  end

  def run_query(id)
    ActiveSupport::Notifications.instrument(DeadBro::SqlSubscriber::SQL_EVENT_NAME,
      sql: "SELECT invoices.* FROM invoices WHERE invoices.id = #{id}", name: "Invoice Load", connection_id: 1) {}
  end

  def perform_job
    job = job_class.new("4f2c-receipt", "mailers", [], nil)
    ActiveSupport::Notifications.instrument("perform_start.active_job", job: job)
    ActiveSupport::Notifications.instrument(DeadBro::JobSubscriber::JOB_EVENT_NAME, job: job) { run_query(7) }
  end

  # A Rack request through SqlTrackingMiddleware to a controller action.
  def run_request(queries: 0, app_strings: 0, exception: nil, &during_action)
    action = lambda do |_env|
      ActiveSupport::Notifications.instrument(DeadBro::Subscriber::EVENT_NAME,
        controller: "InvoicesController", action: "show", format: "html", method: "GET",
        path: "/invoices/42", status: exception ? 500 : 200) do
        queries.times { |i| run_query(i) }
        app_strings.times { +"line item" }
        during_action&.call
        raise exception if exception
      end
      [200, {}, ["ok"]]
    end
    DeadBro::SqlTrackingMiddleware.new(action).call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/invoices/42")
  end

  def request_payloads
    captured_payloads.reject { |c| c[:event_name] == DeadBro::JobSubscriber::JOB_EVENT_NAME }.map { |c| c[:payload] }
  end

  it "stamps the request sample with DeadBro's time and allocations, and clears the meter afterwards" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run_request(queries: 3)
    request_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0

    payload = request_payloads.last
    expect(payload[:agent_overhead_ms]).to be_a(Float).and be > 0
    expect(payload[:agent_overhead_ms]).to be < request_ms
    expect(payload[:agent_allocated_objects]).to be_a(Integer).and be > 0
    expect(Thread.current[DeadBro::OverheadTracker::THREAD_KEY]).to be_nil
  end

  it "counts the SQL listeners' work" do
    run_request(queries: 0)
    run_request(queries: 50)

    without_sql, with_sql = request_payloads.map { |p| p[:agent_allocated_objects] }
    expect(with_sql - without_sql).to be > 50 * 5
  end

  it "doesn't count what the app's own code allocates" do
    run_request(app_strings: 0)
    run_request(app_strings: 20_000)

    quiet, busy = request_payloads.map { |p| p[:agent_allocated_objects] }
    expect((busy - quiet).abs).to be < 200
  end

  it "stamps the sample of a request whose action raised" do
    expect { run_request(queries: 2, exception: ArgumentError.new("invoice total must be positive")) }.to raise_error(ArgumentError)

    payload = request_payloads.last
    expect(payload[:error]).to be true
    expect(payload[:agent_overhead_ms]).to be > 0
    expect(payload[:agent_allocated_objects]).to be > 0
  end

  it "stamps a job sample and pops the job's meter" do
    perform_job

    job_payload = captured_payloads.last[:payload]
    expect(job_payload[:job_class]).to eq("SendReceiptJob")
    expect(job_payload[:agent_overhead_ms]).to be > 0
    expect(job_payload[:agent_allocated_objects]).to be > 0
    expect(Thread.current[DeadBro::OverheadTracker::THREAD_KEY]).to be_nil
  end

  it "measures a job performed inline during a request on its own meter" do
    run_request(queries: 1) { perform_job }

    job_payload = captured_payloads.find { |c| c[:event_name] == DeadBro::JobSubscriber::JOB_EVENT_NAME }[:payload]
    request_payload = request_payloads.last
    expect(job_payload[:agent_allocated_objects]).to be > 0
    expect(request_payload[:agent_allocated_objects]).to be > 0
    expect(Thread.current[DeadBro::OverheadTracker::THREAD_KEY]).to be_nil
  end
end
