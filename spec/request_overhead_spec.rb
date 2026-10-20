# frozen_string_literal: true

require "json"
require "spec_helper"

# What DeadBro costs the host's request thread (DED-191): SqlTrackingMiddleware's
# setup/teardown plus the process_action listener, which runs inside it. Skylight
# measured 10 ms and 121 allocations per request there; the target is < 1 ms and
# < 20 allocations. Everything else — building the payload, JSON, the HTTP POST,
# leak detection — belongs on the dispatcher worker.
RSpec.describe "DeadBro's cost on the request thread" do
  let(:config) { DeadBro.configuration }
  # Stands in for the dispatcher: keeps the jobs so they run after the request.
  let(:dispatcher) do
    Class.new do
      attr_reader :jobs

      def initialize
        @jobs = []
      end

      def dispatch(job = nil, &block)
        @jobs << (job || block)
        true
      end

      def run_jobs
        @jobs.shift.call until @jobs.empty?
      end
    end.new
  end
  let(:posted) { [] }
  let(:client) { DeadBro::Client.new(config) }
  let(:env) do
    {"HTTP_HOST" => "shop.example.com", "HTTP_USER_AGENT" => "Mozilla/5.0 (X11; Linux x86_64) Chrome/141.0", "REQUEST_METHOD" => "GET"}
  end
  let(:request) { Struct.new(:env, :path, :host).new(env, "/orders/42", "shop.example.com") }
  let(:controller_action) do
    lambda do |_env|
      ActiveSupport::Notifications.instrument(
        DeadBro::Subscriber::EVENT_NAME,
        controller: "OrdersController",
        action: "show",
        format: :html,
        method: "GET",
        path: "/orders/42",
        params: {"id" => "42"},
        request: request
      ) do |payload|
        payload[:status] = 200
        payload[:view_runtime] = 4.2
        payload[:db_runtime] = 1.3
      end
      [200, {}, ["ok"]]
    end
  end
  let(:middleware) { DeadBro::SqlTrackingMiddleware.new(controller_action) }

  before do
    DeadBro.reset_configuration!
    config.enabled = true
    config.api_key = "test_key"
    config.sample_rate = 100
    DeadBro::MemoryLeakDetector.clear_history
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)

    # Real jobs, run after the request — as the dispatcher's workers would.
    DeadBro::Dispatcher.inline = false
    DeadBro::Dispatcher.instance_variable_set(:@instance, dispatcher)

    success = double("Response", body: "{}")
    allow(success).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
    http = double("Net::HTTP", "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil)
    allow(http).to receive(:request) do |post|
      posted << JSON.parse(post.body)
      success
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  after do
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    DeadBro::Dispatcher.instance_variable_set(:@instance, nil)
    DeadBro::Dispatcher.inline = true
    DeadBro::MemoryLeakDetector.clear_history
    DeadBro.reset_configuration!
  end

  def allocations
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  end

  # Allocations of one request with DeadBro in the stack, minus the same request
  # without it: setup, teardown, the listener and the notification plumbing its
  # subscription adds.
  def dead_bro_allocations_per_request
    without = Array.new(5) { allocations { controller_action.call(env) } }.min

    DeadBro::Subscriber.subscribe!(client: client)
    3.times { middleware.call(env) } # first requests set up per-thread state
    dispatcher.run_jobs
    with = Array.new(5) { allocations { middleware.call(env) } }.min

    with - without
  end

  it "stays under 20 allocations per request" do
    expect(dead_bro_allocations_per_request).to be < 20
  end

  it "leaves building, encoding and sending the payload to the dispatcher" do
    DeadBro::Subscriber.subscribe!(client: client)
    allow(JSON).to receive(:dump).and_call_original

    middleware.call(env)

    expect(JSON).not_to have_received(:dump)
    expect(posted).to be_empty

    dispatcher.run_jobs

    expect(JSON).to have_received(:dump).once
    expect(posted.size).to eq(1)
    expect(posted.first["payload"]).to include(
      "controller" => "OrdersController",
      "action" => "show",
      "path" => "/orders/42",
      "status" => 200,
      "request_host" => "shop.example.com",
      "params" => {"id" => "42"},
      "sql_count" => 0
    )
  end

  it "builds the same payload fields the request thread used to" do
    DeadBro::Subscriber.subscribe!(client: client)

    middleware.call(env)
    dispatcher.run_jobs

    expect(posted.first["payload"].keys).to match_array(%w[
      view_runtime_ms db_runtime_ms memory_usage gc_stats sql_count sql_queries transaction_events
      http_outgoing cache_events redis_events elasticsearch_events cache_hits cache_misses
      view_events view_performance memory_events memory_performance allocation_phases
      rack_duration_ms queue_duration_ms db_connection_wait_ms db_connection_checkouts gc_pressure
      ar_instantiation_count cpu_time_ms watch_events logs controller action format method path
      status started_at duration_ms host request_host rails_env process_kind params user_agent user_id
    ])
    expect(posted.first["payload"]["gc_stats"].keys).to match_array(%w[count heap_allocated_pages heap_sorted_pages total_allocated_objects])
  end

  it "takes no leak-detection sample on the request thread, and at most one a minute" do
    DeadBro::Subscriber.subscribe!(client: client)
    allow(DeadBro::MemoryLeakDetector).to receive(:record_memory_sample).and_call_original

    2.times { middleware.call(env) }

    expect(DeadBro::MemoryLeakDetector).not_to have_received(:record_memory_sample)

    dispatcher.run_jobs

    expect(DeadBro::MemoryLeakDetector).to have_received(:record_memory_sample).once
  end

  it "reads GC counters one key at a time, never building GC.stat's full Hash" do
    DeadBro::Subscriber.subscribe!(client: client)
    middleware.call(env) # the supported keys are looked up once per process
    allow(GC).to receive(:stat).and_call_original

    middleware.call(env)

    expect(GC).not_to have_received(:stat).with(no_args)
  end

  it "stamps sent_at when the request is reported, not when the worker sends it" do
    DeadBro::Subscriber.subscribe!(client: client)
    middleware.call(env)
    reported_at = Time.now.utc

    allow(Time).to receive(:now).and_return(reported_at + 30)
    dispatcher.run_jobs

    expect(Time.iso8601(posted.first["sent_at"])).to be_within(2).of(reported_at)
  end
end
