# frozen_string_literal: true

require "json"
require "rack"
require "spec_helper"
require "dead_bro/error_middleware"

# DeadBro must never raise into the host app. Rails re-raises a notification
# listener's exception into the instrumented block, so when a bot sent a user
# agent with a stray "\xA1" byte, JSON.dump raised inside the process_action
# callback: the host answered 500 and DeadBro recorded nothing.
RSpec.describe "DeadBro never raising into the host app" do
  let(:bot_user_agent) { "iaskspider/2.0 \xA1".b }
  let(:config) { DeadBro.configuration }
  let(:posted) { [] }

  # The real Client, with the network swapped for a backend that keeps what it receives.
  let(:client) do
    success = double("Response", body: "{}")
    allow(success).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
    http = double("Net::HTTP", "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil)
    allow(http).to receive(:request) do |request|
      posted << JSON.parse(request.body)
      success
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
    DeadBro::Client.new(config)
  end

  let(:failing_client) do
    instance_double(DeadBro::Client).tap do |failing|
      allow(failing).to receive(:post_metric).and_raise(JSON::GeneratorError, "source sequence is illegal/malformed utf-8")
    end
  end

  before do
    DeadBro.reset_configuration!
    config.enabled = true
    config.api_key = "test_key"
    config.sample_rate = 100
    unsubscribe_all
  end

  after do
    unsubscribe_all
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::CacheSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
    Thread.current[:dead_bro_alloc_active] = nil
  end

  def unsubscribe_all
    events = [DeadBro::Subscriber::EVENT_NAME, DeadBro::JobSubscriber::JOB_EVENT_NAME, DeadBro::SqlSubscriber::SQL_EVENT_NAME]
    (events + DeadBro::CacheSubscriber::EVENTS).each { |event| ActiveSupport::Notifications.unsubscribe(event) }
  end

  describe "web requests" do
    def process_action(user_agent:, format: "html", exception_object: nil)
      request = double("ActionDispatch::Request", user_agent: user_agent, host: "shop.example.com")
      ActiveSupport::Notifications.instrument(
        DeadBro::Subscriber::EVENT_NAME,
        controller: "PagesController",
        action: "home",
        format: format,
        method: "GET",
        path: "/",
        status: exception_object ? 500 : 200,
        request: request,
        exception: exception_object && [exception_object.class.name, exception_object.message],
        exception_object: exception_object
      ) {}
    end

    it "answers and records a request whose user agent isn't valid UTF-8" do
      DeadBro::Subscriber.subscribe!(client: client)

      expect { process_action(user_agent: bot_user_agent) }.not_to raise_error

      expect(posted.size).to eq(1)
      expect(posted.first["payload"]).to include(
        "controller" => "PagesController",
        "action" => "home",
        "user_agent" => "iaskspider/2.0 �"
      )
    end

    it "records the host's own exception when its message quotes invalid bytes" do
      DeadBro::Subscriber.subscribe!(client: client)
      error = RuntimeError.new("Couldn't find Page with 'slug'=\xA1".dup.force_encoding(Encoding::UTF_8))
      error.set_backtrace(["app/controllers/pages_controller.rb:5:in `home'"])

      process_action(user_agent: bot_user_agent, exception_object: error)

      expect(posted.size).to eq(1)
      expect(posted.first["payload"]).to include(
        "error" => true,
        "message" => "Couldn't find Page with 'slug'=�",
        "user_agent" => "iaskspider/2.0 �"
      )
      expect(posted.first["payload"]["fingerprint"]).to match(/\A\h{16}\z/)
    end

    it "still records the request when a field the subscriber doesn't scrub carries invalid bytes" do
      DeadBro::Subscriber.subscribe!(client: client)

      # An unregistered MIME type from the Accept header comes through as the raw header bytes.
      process_action(user_agent: "curl/8.0", format: "text/\xA1".b)

      expect(posted.first["payload"]["format"]).to eq("text/�")
      expect(client.serialization_failures).to eq(0)
    end

    it "answers the request even when reporting it raises" do
      DeadBro::Subscriber.subscribe!(client: failing_client)

      expect { process_action(user_agent: "curl/8.0") }.not_to raise_error
    end

    it "keeps the request off the client's slow retry path when the user agent ends up in a cache key" do
      allow(DeadBro::Sanitizer).to receive(:deep).and_call_original
      DeadBro::Subscriber.subscribe!(client: client)
      DeadBro::CacheSubscriber.subscribe!
      DeadBro::CacheSubscriber.start_request_tracking

      # e.g. a rate limiter throttling by user agent
      ActiveSupport::Notifications.instrument("cache_write.active_support", key: "throttle:#{bot_user_agent}") {}
      process_action(user_agent: bot_user_agent)

      expect(posted.first["payload"]["cache_events"].first["key"]).to eq("throttle:iaskspider/2.0 �")
      expect(DeadBro::Sanitizer).not_to have_received(:deep)
    end
  end

  describe "background jobs" do
    let(:job) do
      job_class = double("JobClass", name: "ImportJob")
      double("Job", job_id: "job-1", queue_name: "default", arguments: [], enqueued_at: nil).tap do |job|
        allow(job).to receive(:class).and_return(job_class)
      end
    end

    def perform(&block)
      ActiveSupport::Notifications.instrument(DeadBro::JobSubscriber::JOB_EVENT_NAME, job: job, &(block || proc {}))
    end

    it "lets the job finish when reporting it raises" do
      DeadBro::JobSubscriber.subscribe!(client: failing_client)

      expect { perform }.not_to raise_error
    end

    it "surfaces the job's own exception unchanged when reporting it raises" do
      DeadBro::JobSubscriber.subscribe!(client: failing_client)
      error = RuntimeError.new("import failed")

      expect { perform { raise error } }.to raise_error(error)
    end

    it "releases the job's tracking state when building its payload raises" do
      DeadBro::JobSubscriber.subscribe!(client: client)
      # What JobSqlTrackingMiddleware does on perform_start.
      DeadBro::SqlSubscriber.start_request_tracking
      allow(config).to receive(:should_sample?).and_raise(NoMethodError)

      expect { perform }.not_to raise_error
      # Nothing else resets thread-locals after a job, so a leaked frame would
      # collect the next job's queries on this worker thread.
      expect(DeadBro::SqlSubscriber.tracking_active?).to be false
    end
  end

  describe "SQL queries" do
    let(:sql) { "SELECT * FROM visits WHERE user_agent = '\xA1'".dup.force_encoding(Encoding::UTF_8) }

    def run_query
      ActiveSupport::Notifications.instrument(DeadBro::SqlSubscriber::SQL_EVENT_NAME, sql: sql, name: "Visit Load") {}
    end

    before do
      DeadBro::SqlSubscriber.subscribe!
      DeadBro::SqlSubscriber.start_request_tracking
    end

    it "records a query whose SQL isn't valid UTF-8 instead of failing it" do
      expect { run_query }.not_to raise_error

      queries = DeadBro::SqlSubscriber.stop_request_tracking
      expect(queries.size).to eq(1)
      expect(queries.first[:sql]).to eq("SELECT * FROM visits WHERE user_agent = ?")
    end

    it "records it without an EXPLAIN when it's slow enough to be explained" do
      config.explain_enabled = true
      config.slow_query_threshold_ms = 0

      expect { run_query }.not_to raise_error

      queries = DeadBro::SqlSubscriber.stop_request_tracking
      expect(queries.size).to eq(1)
      expect(queries.first[:explain_plan]).to be_nil
    end
  end

  describe DeadBro::SqlTrackingMiddleware do
    let(:app) { ->(_env) { [200, {}, ["ok"]] } }

    before do
      # Put the request on the allocation-tracking path without really tracing.
      allow(config).to receive(:allocation_tracking_active?).and_return(true)
      allow(DeadBro::MemoryTrackingSubscriber).to receive(:start_request_tracking)
      allow(DeadBro::AllocationSourceSampler).to receive(:start)
      allow(DeadBro::AllocationSourceSampler).to receive(:stop)
    end

    it "serves the request when tracking setup raises" do
      allow(DeadBro::SqlSubscriber).to receive(:start_request_tracking).and_raise(NoMethodError)

      expect(described_class.new(app).call({})).to eq([200, {}, ["ok"]])
    end

    it "keeps the host's response and finishes teardown when stopping the sampler raises" do
      allow(DeadBro::AllocationSourceSampler).to receive(:stop).and_raise(NoMethodError)

      expect(described_class.new(app).call({})).to eq([200, {}, ["ok"]])
      expect(Thread.current[:dead_bro_alloc_active]).to be_nil
      expect(Thread.current[DeadBro::TRACKING_START_TIME_KEY]).to be_nil
    end

    it "still stops the sampler when an earlier teardown step raises" do
      db_connections = double("DbConnectionSubscriber", start_request_tracking: nil)
      allow(db_connections).to receive(:stop_request_tracking).and_raise(NoMethodError)
      stub_const("DeadBro::DbConnectionSubscriber", db_connections)

      expect(described_class.new(app).call({})).to eq([200, {}, ["ok"]])
      expect(DeadBro::AllocationSourceSampler).to have_received(:stop)
      expect(Thread.current[DeadBro::GcTracker::THREAD_KEY]).to be_nil
    end
  end

  describe DeadBro::ErrorMiddleware do
    let(:error) { RuntimeError.new("No route matches [GET] \"/\xA1\"".dup.force_encoding(Encoding::UTF_8)) }
    let(:app) { ->(_env) { raise error } }
    let(:env) do
      Rack::MockRequest.env_for("/pages", "HTTP_USER_AGENT" => bot_user_agent, "HTTP_REFERER" => "https://example.com/\xA1".b)
    end

    it "reports an uncaught exception from a request with invalid UTF-8 headers, then re-raises it" do
      expect { described_class.new(app, client).call(env) }.to raise_error(error)

      expect(posted.size).to eq(1)
      payload = posted.first["payload"]
      expect(payload["message"]).to eq("No route matches [GET] \"/�\"")
      expect(payload["fingerprint"]).to match(/\A\h{16}\z/)
      expect(payload["rack"]).to include(
        "user_agent" => "iaskspider/2.0 �",
        "referer" => "https://example.com/�"
      )
    end

    it "re-raises the host's exception, not ours, when reporting fails" do
      stack_overflowing_client = instance_double(DeadBro::Client)
      allow(stack_overflowing_client).to receive(:post_metric).and_raise(SystemStackError)

      expect { described_class.new(app, stack_overflowing_client).call(env) }.to raise_error(error)
    end

    it "keeps params, still redacted, when a key isn't valid UTF-8" do
      bad_key = "na\xA1me".dup.force_encoding(Encoding::UTF_8)

      redacted = described_class.new(app, client).send(:redact_sensitive, {bad_key => "x", "password" => "secret"})

      expect(redacted).to eq("na�me" => "x", "password" => "[FILTERED]")
    end
  end

  # Strings captured from the host's own data are scrubbed where they're
  # captured, so one bad byte doesn't send the whole payload down the client's
  # slow scrub-and-retry path (a full copy on the request thread).
  describe "strings captured from host data" do
    after { DeadBro.logger.clear }

    it "scrubs Redis keys" do
      event = DeadBro::RedisSubscriber.build_event("redis.command", {command: ["GET", "session:\xA1".b]}, 0.1)

      expect(event[:key]).to eq("session:�")
    end

    it "scrubs job arguments" do
      args = DeadBro::JobSubscriber.send(:safe_arguments, ["bot \xA1".b, {"ua" => "bot \xA1".b}, ["bot \xA1".b]])

      expect(args).to eq(["bot �", {"ua" => "bot �"}, ["bot �"]])
    end

    it "scrubs log messages" do
      DeadBro.logger.clear
      DeadBro.logger.info("throttled bot \xA1".b)

      expect(DeadBro.logger.logs.last[:msg]).to eq("throttled bot �")
    end
  end
end
