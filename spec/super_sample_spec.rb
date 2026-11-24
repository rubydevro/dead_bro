# frozen_string_literal: true

require "spec_helper"
require "dead_bro/sql_tracking_middleware"
require "dead_bro/job_sql_tracking_middleware"
require "dead_bro/http_instrumentation"

RSpec.describe DeadBro::SuperSample do
  let(:config) { DeadBro.configuration }
  let(:posted) { [] }
  let(:client) do
    instance_double(DeadBro::Client).tap do |double|
      allow(double).to receive(:post_metric) { |**kwargs| posted << kwargs }
      allow(double).to receive(:post_heartbeat)
    end
  end

  def job(arguments = [])
    stub_const("ReportJob", Class.new do
      attr_reader :arguments

      def initialize(arguments)
        @arguments = arguments
      end

      def job_id
        "5f0c1c9e"
      end

      def queue_name
        "default"
      end

      def enqueued_at
      end
    end)
    ReportJob.new(arguments)
  end

  def events
    [DeadBro::Subscriber::EVENT_NAME, "start_processing.action_controller", "perform_start.active_job",
      DeadBro::JobSubscriber::JOB_EVENT_NAME, DeadBro::SqlSubscriber::SQL_EVENT_NAME] + DeadBro::CacheSubscriber::EVENTS
  end

  def reset_thread
    [described_class::REQUEST_KEY, described_class::JOB_KEY, DeadBro::SpanTracker::THREAD_KEY,
      DeadBro::SqlSubscriber::THREAD_LOCAL_KEY, DeadBro::SqlSubscriber::THREAD_LOCAL_AGGREGATES_KEY,
      DeadBro::SqlSubscriber::THREAD_LOCAL_CALL_COUNTS_KEY, DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY,
      DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY, DeadBro::CacheSubscriber::THREAD_LOCAL_KEY,
      DeadBro::RedisSubscriber::THREAD_LOCAL_KEY, DeadBro::HttpInstrumentation::THREAD_LOCAL_KEY,
      DeadBro::ElasticsearchSubscriber::THREAD_LOCAL_KEY, DeadBro::ViewRenderingSubscriber::THREAD_LOCAL_KEY,
      DeadBro::ViewRenderingSubscriber::THREAD_LOCAL_AGGREGATES_KEY, DeadBro::WatchTracker::THREAD_LOCAL_EVENTS_KEY,
      DeadBro::WatchTracker::THREAD_LOCAL_ACTIVE_STACK_KEY, DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY,
      DeadBro::TRACKING_START_TIME_KEY].each { |key| Thread.current[key] = nil }
  end

  before do
    DeadBro.reset_configuration!
    config.enabled = true
    events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    reset_thread
    # The logger also prints every entry.
    allow(DeadBro.logger).to receive(:print_log)
    DeadBro::Subscriber.subscribe!(client: client)
    DeadBro::JobSqlTrackingMiddleware.subscribe!
    DeadBro::JobSubscriber.subscribe!(client: client)
    DeadBro::SqlSubscriber.subscribe!
    DeadBro::CacheSubscriber.subscribe!
    DeadBro::SpanTracker.subscribe!
  end

  after do
    events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    reset_thread
  end

  # The 1% draw: a hit, or a miss.
  def draw(hit)
    allow(described_class).to receive(:rand).and_return(hit ? 0.0 : 0.5)
  end

  # What Rails does for one request: DeadBro's middleware, whatever runs
  # between it and the controller (before_action), then start_processing and
  # the action inside process_action. Returns the payload sent for it, nil when
  # nothing was sent.
  def request(controller: "OrdersController", action: "index", before_action: nil, **fields, &body)
    sent = posted.size
    app = DeadBro::SqlTrackingMiddleware.new(lambda do |_env|
      before_action&.call
      payload = {controller: controller, action: action, format: "html", method: "GET", path: "/orders", status: 200}.merge(fields)
      ActiveSupport::Notifications.instrument("start_processing.action_controller", payload)
      ActiveSupport::Notifications.instrument(DeadBro::Subscriber::EVENT_NAME, payload) { body&.call }
      [200, {}, ["ok"]]
    end)
    begin
      app.call({})
    rescue RuntimeError
      # The action's own exception, raised on through the middleware.
    end
    posted[sent]&.fetch(:payload)
  end

  # What Active Job does for one job. Returns the payload sent for it.
  def perform(job)
    sent = posted.size
    ActiveSupport::Notifications.instrument("perform_start.active_job", job: job)
    begin
      ActiveSupport::Notifications.instrument(DeadBro::JobSubscriber::JOB_EVENT_NAME, job: job) { yield if block_given? }
    rescue RuntimeError
      # The job's own exception.
    end
    posted[sent]&.fetch(:payload)
  end

  def sql(statement)
    ActiveSupport::Notifications.instrument("sql.active_record", sql: statement, name: "Order Load", connection_id: 1) {}
  end

  def cache_read(key)
    ActiveSupport::Notifications.instrument("cache_read.active_support", key: key, hit: true) {}
  end

  # Both ways: as an ordinary sample, then as a super sample. Yields whether
  # it is the super sample.
  def ordinary_then_super
    draw(false)
    ordinary = yield(false)
    draw(true)
    [ordinary, yield(true)]
  end

  describe "the super_samples_by_type setting" do
    it "is empty until the backend asks for super samples" do
      expect(config.super_samples_by_type).to eq({})
    end

    it "takes the numbers of a settings response and replaces them with the next one's" do
      config.apply_remote_settings("super_samples_by_type" => {"OrdersController#index" => "3", :"ReportJob#perform" => 1})
      expect(config.super_samples_by_type).to eq("OrdersController#index" => 3, "ReportJob#perform" => 1)

      config.apply_remote_settings("super_samples_by_type" => {"OrdersController#index" => 2})
      expect(config.super_samples_by_type).to eq("OrdersController#index" => 2)
    end

    it "takes any number: there is no upper limit" do
      config.apply_remote_settings("super_samples_by_type" => {"OrdersController#index" => 250_000})

      expect(config.super_samples_by_type).to eq("OrdersController#index" => 250_000)
    end

    it "keeps its numbers when a settings response doesn't carry the key" do
      config.apply_remote_settings("super_samples_by_type" => {"OrdersController#index" => 3})
      config.apply_remote_settings("sample_rate" => 50)

      expect(config.super_samples_by_type).to eq("OrdersController#index" => 3)
    end

    it "is empty for anything that isn't a hash" do
      config.apply_remote_settings("super_samples_by_type" => {"OrdersController#index" => 3})
      config.apply_remote_settings("super_samples_by_type" => nil)

      expect(config.super_samples_by_type).to eq({})
    end
  end

  describe "a request" do
    it "is sent as a super sample when it is drawn and its type needs one" do
      config.super_samples_by_type = {"OrdersController#index" => 2}
      draw(true)

      expect(request[:super_sample]).to be true
    end

    it "is sent as usual when it isn't drawn" do
      config.super_samples_by_type = {"OrdersController#index" => 2}
      draw(false)

      expect(request).not_to have_key(:super_sample)
    end

    it "is drawn with a 1% chance" do
      config.super_samples_by_type = {"OrdersController#index" => 2}

      allow(described_class).to receive(:rand).and_return(0.0099)
      expect(request[:super_sample]).to be true

      allow(described_class).to receive(:rand).and_return(0.01)
      expect(request).not_to have_key(:super_sample)
    end

    it "is sent as usual when it is drawn and its type needs none" do
      config.super_samples_by_type = {"OrdersController#index" => 0, "InvoicesController#show" => 4}
      draw(true)
      active_in_action = nil

      expect(request { active_in_action = described_class.active? }).not_to have_key(:super_sample)
      expect(request(action: "show")).not_to have_key(:super_sample)
      expect(active_in_action).to be false
    end

    it "isn't drawn while no type needs a super sample" do
      expect(described_class).not_to receive(:rand)

      expect(request).not_to have_key(:super_sample)
    end

    it "is sent as a super sample whatever the sample rate" do
      config.sample_rates_by_type = {"OrdersController#index" => 0}
      config.super_samples_by_type = {"OrdersController#index" => 1}

      ordinary, whole = ordinary_then_super { request }

      expect(ordinary).to be_nil
      expect(whole[:super_sample]).to be true
    end

    it "marks its error report when it raised" do
      config.super_samples_by_type = {"OrdersController#index" => 1}
      draw(true)

      payload = request { raise "no stock left" }

      expect(payload).to include(error: true, super_sample: true)
    end

    it "stops being one when its action has finished" do
      config.super_samples_by_type = {"OrdersController#index" => 1}
      draw(true)
      active_in_action = nil

      request { active_in_action = described_class.active? }

      expect(active_in_action).to be true
      expect(described_class.active?).to be false
    end

    it "stops being drawn when it leaves the middleware without reaching a controller action" do
      config.super_samples_by_type = {"OrdersController#index" => 1}
      draw(true)
      active_in_app = nil

      not_found = lambda do |_env|
        active_in_app = described_class.active?
        [404, {}, []]
      end
      DeadBro::SqlTrackingMiddleware.new(not_found).call({})

      expect(active_in_app).to be true
      expect(described_class.active?).to be false
      expect(posted).to be_empty
    end
  end

  describe "a job" do
    it "is sent as a super sample when it is drawn and its type needs one" do
      config.super_samples_by_type = {"ReportJob#perform" => 1}
      draw(true)
      active_in_job = nil

      payload = perform(job) { active_in_job = described_class.active? }

      expect(payload).to include(job_class: "ReportJob", super_sample: true)
      expect(active_in_job).to be true
      expect(described_class.active?).to be false
    end

    it "is sent as usual when it isn't drawn, or its type needs none" do
      config.super_samples_by_type = {"ReportJob#perform" => 1}
      draw(false)
      expect(perform(job)).not_to have_key(:super_sample)

      config.super_samples_by_type = {"OrdersController#index" => 1}
      draw(true)
      expect(perform(job)).not_to have_key(:super_sample)
    end

    it "is sent as a super sample whatever the sample rate" do
      config.sample_rates_by_type = {"ReportJob#perform" => 0}
      config.super_samples_by_type = {"ReportJob#perform" => 1}

      ordinary, whole = ordinary_then_super { perform(job) }

      expect(ordinary).to be_nil
      expect(whole[:super_sample]).to be true
    end

    it "is drawn apart from the request it is performed in" do
      config.super_samples_by_type = {"OrdersController#index" => 1}
      draw(true)

      described_class.start_tracking
      described_class.start_request(controller: "OrdersController", action: "index")
      described_class.start_job(job)

      expect(described_class.job?).to be false
      described_class.finish_job
      expect(described_class.request?).to be true
    end
  end

  describe "what a super sample records" do
    before { config.super_samples_by_type = {"OrdersController#index" => 1, "ReportJob#perform" => 1} }

    let(:log_entries) { DeadBro::Logger::MAX_LOG_ENTRIES + 20 }
    let(:statements) { DeadBro::SpanTracker::MAX_NODES + 20 }

    it "keeps every log entry" do
      ordinary, whole = ordinary_then_super do
        request { log_entries.times { |i| DeadBro.logger.info("line #{i}") } }
      end

      # The cap, and the entry that says how many were dropped.
      expect(ordinary[:logs].size).to eq(DeadBro::Logger::MAX_LOG_ENTRIES + 1)
      expect(whole[:logs].size).to eq(log_entries)
      expect(whole[:logs].last[:msg]).to eq("line #{log_entries - 1}")
    end

    it "keeps every log entry of a job" do
      draw(true)

      payload = perform(job) { log_entries.times { |i| DeadBro.logger.info("line #{i}") } }

      expect(payload[:logs].size).to eq(log_entries)
    end

    it "keeps every span" do
      ordinary, whole = ordinary_then_super do
        request { statements.times { |i| sql("SELECT * FROM orders_#{i}") } }
      end

      expect(ordinary[:spans].size).to eq(DeadBro::SpanTracker::MAX_NODES)
      expect(ordinary[:spans_dropped]).to be > 0
      expect(whole[:spans].count { |span| span[:kind] == "sql" }).to eq(statements)
      expect(whole).not_to have_key(:spans_dropped)
    end

    it "has no limits from DeadBro's middleware on, before the controller action starts" do
      key = "throttle/" + "k" * 300

      ordinary, whole = ordinary_then_super do
        request(before_action: -> { cache_read(key) })
      end

      expect(ordinary[:cache_events].first[:key].length).to eq(201)
      expect(whole[:cache_events].first[:key]).to eq(key)
    end

    [DeadBro::CacheSubscriber, DeadBro::RedisSubscriber, DeadBro::HttpInstrumentation, DeadBro::ElasticsearchSubscriber].each do |subscriber|
      it "keeps recording #{subscriber.name.split("::").last} events past the cap and the time limit" do
        at_the_cap = Array.new(subscriber::MAX_TRACKED_EVENTS) { {} }
        Thread.current[subscriber::THREAD_LOCAL_KEY] = at_the_cap
        expect(subscriber.should_continue_tracking?).to be false

        Thread.current[subscriber::THREAD_LOCAL_KEY] = []
        Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now - DeadBro::MAX_TRACKING_DURATION_SECONDS - 1
        expect(subscriber.should_continue_tracking?).to be false

        Thread.current[subscriber::THREAD_LOCAL_KEY] = at_the_cap
        Thread.current[described_class::REQUEST_KEY] = true
        expect(subscriber.should_continue_tracking?).to be true
      end
    end

    it "keeps every view past the cap" do
      views = DeadBro::ViewRenderingSubscriber::MAX_TRACKED_EVENTS + 5
      render_views = lambda do
        DeadBro::ViewRenderingSubscriber.start_request_tracking
        views.times { |i| DeadBro::ViewRenderingSubscriber.add_view_event(identifier: "orders/_row_#{i}.html.erb", duration_ms: 1.0) }
        DeadBro::ViewRenderingSubscriber.stop_request_tracking.size
      end

      expect(render_views.call).to eq(DeadBro::ViewRenderingSubscriber::MAX_TRACKED_EVENTS)

      Thread.current[described_class::REQUEST_KEY] = true
      expect(render_views.call).to eq(views)
    end

    it "keeps every DeadBro.watch block, however many and however deep" do
      config.watch_enabled = true
      blocks = DeadBro::WatchTracker::MAX_SPANS_PER_REQUEST + 5
      levels = DeadBro::WatchTracker::MAX_DEPTH + 4
      nest = ->(level) { DeadBro::WatchTracker.watch("level #{level}") { nest.call(level + 1) if level < levels } }
      watch_blocks = lambda do |&work|
        DeadBro::WatchTracker.start_request_tracking
        work.call
        DeadBro::WatchTracker.stop_request_tracking.size
      end
      many = -> { blocks.times { |i| DeadBro::WatchTracker.watch("step #{i}") {} } }
      deep = -> { nest.call(1) }

      expect(watch_blocks.call(&many)).to eq(DeadBro::WatchTracker::MAX_SPANS_PER_REQUEST)
      expect(watch_blocks.call(&deep)).to eq(DeadBro::WatchTracker::MAX_DEPTH + 1)

      Thread.current[described_class::REQUEST_KEY] = true
      expect(watch_blocks.call(&many)).to eq(blocks)
      expect(watch_blocks.call(&deep)).to eq(levels)
    end

    it "keeps every transaction event past the cap" do
      transactions = DeadBro::SqlSubscriber::MAX_TRACKED_TXN_EVENTS + 5
      now = Time.now
      run_transactions = lambda do
        DeadBro::SqlSubscriber.start_request_tracking
        transactions.times { DeadBro::SqlSubscriber.record_transaction_event("BEGIN", now, now) }
        DeadBro::SqlSubscriber.stop_request_tracking
        DeadBro::SqlSubscriber.last_transaction_events.size
      end

      expect(run_transactions.call).to eq(DeadBro::SqlSubscriber::MAX_TRACKED_TXN_EVENTS)

      Thread.current[described_class::REQUEST_KEY] = true
      expect(run_transactions.call).to eq(transactions)
    end
  end

  describe "what a super sample leaves whole" do
    before { config.super_samples_by_type = {"OrdersController#index" => 1, "ReportJob#perform" => 1} }

    it "the SQL text" do
      statement = "SELECT #{(1..400).map { |i| "orders.column_#{i}" }.join(", ")} FROM orders"

      ordinary, whole = ordinary_then_super { request { sql(statement) } }

      expect(ordinary[:sql_queries].first[:sql].length).to eq(DeadBro::SqlSubscriber::SANITIZE_MAX_LENGTH + 1 + "...".length)
      expect(whole[:sql_queries].first[:sql]).to eq(statement)
    end

    it "the params, with their sensitive values still filtered" do
      params = {
        "note" => "n" * 500,
        "ids" => (1..25).to_a,
        "filters" => (1..35).to_h { |i| ["filter_#{i}", i] },
        "password" => "correct horse"
      }

      ordinary, whole = ordinary_then_super { request(params: params) }

      expect(ordinary[:params]).to include("note" => "#{"n" * 200}…", "ids" => (1..20).to_a, "password" => "[FILTERED]")
      expect(ordinary[:params]["filters"].size).to eq(30)
      expect(whole[:params]).to eq(params.merge("password" => "[FILTERED]"))
    end

    it "the user agent" do
      user_agent = "OrdersClient/2.4 (#{"x" * 300})"

      ordinary, whole = ordinary_then_super { request(env: {"HTTP_USER_AGENT" => user_agent}) }

      expect(ordinary[:user_agent].length).to eq(201)
      expect(whole[:user_agent]).to eq(user_agent)
    end

    it "an error's message and backtrace" do
      backtrace = Array.new(60) { |i| "app/models/order.rb:#{i + 1}:in `total'" }
      raise_long = -> { raise RuntimeError, "m" * 1_500, backtrace }

      ordinary, whole = ordinary_then_super { request { raise_long.call } }

      expect(ordinary[:message].length).to eq(1_000)
      expect(ordinary[:backtrace].size).to eq(50)
      expect(whole[:message].length).to eq(1_500)
      expect(whole[:backtrace]).to eq(backtrace)
    end

    it "an error's causes, each with its message and backtrace" do
      error = RuntimeError.new("the first cause")
      7.times do
        raise RuntimeError, "c" * 600, Array.new(5) { |i| "app/services/billing.rb:#{i + 1}" }, cause: error
      rescue => wrapped
        error = wrapped
      end

      ordinary = DeadBro::Subscriber.build_cause_chain(error)
      Thread.current[described_class::REQUEST_KEY] = true
      whole = DeadBro::Subscriber.build_cause_chain(error)

      expect(ordinary.size).to eq(5)
      expect(ordinary.first).to include(message: "c" * 500, backtrace_top: Array.new(3) { |i| "app/services/billing.rb:#{i + 1}" })
      expect(whole.size).to eq(7)
      expect(whole.first[:message].length).to eq(600)
      expect(whole.first[:backtrace_top].size).to eq(5)
    end

    it "a job's arguments, with their sensitive keys still filtered" do
      options = (1..25).to_h { |i| ["option_#{i}", i] }
      arguments = ["a" * 300, options.merge("password" => "correct horse"), (1..8).to_a] + Array.new(9) { |i| "extra #{i}" }

      ordinary, whole = ordinary_then_super { perform(job(arguments)) }

      expect(ordinary[:arguments].size).to eq(10)
      expect(ordinary[:arguments][0]).to eq("#{"a" * 200}...")
      expect(ordinary[:arguments][1].size).to eq(20)
      expect(ordinary[:arguments][2]).to eq((1..5).to_a)
      expect(whole[:arguments]).to eq(["a" * 300, options, (1..8).to_a] + Array.new(9) { |i| "extra #{i}" })
    end

    it "a failed job's message and backtrace" do
      backtrace = Array.new(60) { |i| "app/jobs/report_job.rb:#{i + 1}:in `perform'" }
      raise_long = -> { raise RuntimeError, "m" * 1_500, backtrace }

      ordinary, whole = ordinary_then_super { perform(job) { raise_long.call } }

      expect(ordinary[:message].length).to eq(1_000)
      expect(ordinary[:backtrace].size).to eq(50)
      expect(whole[:message].length).to eq(1_500)
      expect(whole[:backtrace]).to eq(backtrace)
    end

    it "cache and Redis keys" do
      key = "k" * 300
      keys = -> { [DeadBro::CacheSubscriber.safe_key(key), DeadBro::RedisSubscriber.safe_key(key), DeadBro::CacheSubscriber.safe_namespace(key)] }

      expect(keys.call.map(&:length)).to eq([201, 201, 100])

      Thread.current[described_class::REQUEST_KEY] = true
      expect(keys.call).to eq([key, key, key])
    end

    it "a DeadBro.watch block's label and tags" do
      config.watch_enabled = true
      label = "l" * 300
      tags = (1..7).to_h { |i| [:"tag_#{i}", "v" * 150] }
      watched = lambda do
        DeadBro::WatchTracker.start_request_tracking
        DeadBro::WatchTracker.watch(label, **tags) {}
        DeadBro::WatchTracker.stop_request_tracking.first
      end

      ordinary = watched.call
      Thread.current[described_class::REQUEST_KEY] = true
      whole = watched.call

      expect(ordinary[:label]).to eq("#{"l" * 200}...")
      expect(ordinary[:tags].size).to eq(5)
      expect(ordinary[:tags].values.first.length).to eq(103)
      expect(whole[:label]).to eq(label)
      expect(whole[:tags]).to eq(tags.transform_keys(&:to_s))
    end

    it "its payload: max_sql_queries_to_send and max_logs_to_send cut nothing" do
      config.max_sql_queries_to_send = 3
      config.max_logs_to_send = 2
      payload = {
        controller: "OrdersController",
        sql_queries: (1..10).map { |i| {sql: "SELECT #{i}"} },
        logs: (1..5).map { |i| {msg: "line #{i}"} }
      }
      http_client = DeadBro::Client.new(config)

      cut = http_client.send(:truncate_payload_for_request, payload)
      expect(cut[:sql_queries].size).to eq(3)
      expect(cut[:logs].size).to eq(2)

      whole = http_client.send(:truncate_payload_for_request, payload.merge(super_sample: true))
      expect(whole[:sql_queries].size).to eq(10)
      expect(whole[:logs].size).to eq(5)
      expect(whole).not_to have_key(:sql_queries_total_count)
      expect(whole).not_to have_key(:logs_total_count)
    end
  end
end
