# frozen_string_literal: true

require "rack"
require "spec_helper"
require "dead_bro/sql_tracking_middleware"

RSpec.describe DeadBro::SpanTracker do
  let(:config) { DeadBro.configuration }
  let(:posted) { [] }
  let(:client) do
    instance_double(DeadBro::Client).tap do |double|
      allow(double).to receive(:post_metric) { |**kwargs| posted << kwargs }
      allow(double).to receive(:post_heartbeat)
    end
  end

  def events
    [DeadBro::Subscriber::EVENT_NAME, "start_processing.action_controller", DeadBro::SqlSubscriber::SQL_EVENT_NAME] +
      described_class::VIEW_EVENTS.keys + DeadBro::CacheSubscriber::EVENTS
  end

  def reset_thread
    Thread.current[described_class::THREAD_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_AGGREGATES_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_CALL_COUNTS_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  before do
    DeadBro.reset_configuration!
    config.enabled = true
    config.sample_rate = 100
    events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    reset_thread
    DeadBro::Subscriber.subscribe!(client: client)
    DeadBro::SqlSubscriber.subscribe!
    DeadBro::CacheSubscriber.subscribe!
    DeadBro::ViewRenderingSubscriber.subscribe!
    described_class.subscribe!
  end

  after do
    events.each { |event| ActiveSupport::Notifications.unsubscribe(event) }
    reset_thread
  end

  def probe(app, name, kind = described_class::MIDDLEWARE)
    DeadBro::MiddlewareProbe.new(app, name, kind)
  end

  # A middleware that runs `before` on the way in and `after` on the way out.
  def middleware(app, before: nil, after: nil)
    lambda do |env|
      before&.call
      response = app.call(env)
      after&.call
      response
    end
  end

  def sql(statement, name = "Post Load")
    ActiveSupport::Notifications.instrument("sql.active_record", sql: statement, name: name, connection_id: 1) {}
  end

  def render(event, path)
    ActiveSupport::Notifications.instrument("render_#{event}.action_view", identifier: "/srv/app/app/views/#{path}") { yield if block_given? }
  end

  # What Rails' router does for one action: start_processing, then the action
  # inside process_action.
  def router(controller: "PostsController", action: "index", &body)
    lambda do |_env|
      payload = {controller: controller, action: action, format: "html", method: "GET", path: "/posts", status: 200}
      ActiveSupport::Notifications.instrument("start_processing.action_controller", payload)
      # instrument adds :exception and :exception_object when the block raises
      ActiveSupport::Notifications.instrument(DeadBro::Subscriber::EVENT_NAME, payload) { body&.call }
      [200, {}, ["ok"]]
    end
  end

  # The probes Rails' middleware stack gets: one per middleware and one around
  # the router. DeadBro's SqlTrackingMiddleware is the innermost middleware.
  def rails_stack(endpoint, session_after: nil)
    routes = probe(endpoint, "ActionDispatch::Routing::RouteSet", described_class::ENDPOINT)
    tracking = probe(DeadBro::SqlTrackingMiddleware.new(routes), "DeadBro::SqlTrackingMiddleware")
    session = probe(middleware(tracking, after: session_after), "ActionDispatch::Session::CookieStore")
    probe(middleware(session), "ActionDispatch::HostAuthorization")
  end

  def spans_of(payload)
    payload[:spans].each_with_object({}) { |node, by_name| by_name[node[:name] || "sql:#{node[:ref]}"] = node }
  end

  it "nests the action, views and queries and folds repeated calls on a path into one node" do
    app = rails_stack(router do
      sql("SELECT * FROM posts")
      sql("SELECT * FROM authors WHERE id = 7")
      render(:template, "posts/index.html.erb") do
        3.times do |i|
          render(:partial, "posts/_post.html.erb") do
            sql("SELECT * FROM authors WHERE id = #{i}")
            ActiveSupport::Notifications.instrument("cache_read.active_support", key: "post/#{i}", hit: true) {}
          end
        end
      end
    end)

    app.call({})

    expect(posted.size).to eq(1)
    payload = posted.first[:payload]
    nodes = spans_of(payload)
    action = nodes.fetch("PostsController#index")
    template = nodes.fetch("views/posts/index.html.erb")
    partial = nodes.fetch("views/posts/_post.html.erb")

    expect(action).to include(kind: "action", count: 1, parent_id: nodes.fetch("ActionDispatch::Routing::RouteSet")[:id])
    expect(template).to include(kind: "view", type: "template", count: 1, parent_id: action[:id])
    expect(partial).to include(kind: "view", type: "partial", count: 3, parent_id: template[:id])

    authors = payload[:sql_queries].find { |q| q[:sql].include?("authors") }
    author_nodes = payload[:spans].select { |node| node[:kind] == "sql" && node[:ref] == authors[:id] }
    expect(author_nodes.map { |node| [node[:parent_id], node[:count]] }).to contain_exactly([action[:id], 1], [partial[:id], 3])
    expect(authors[:count]).to eq(4)

    expect(payload[:cache_events].map { |event| event[:parent_id] }).to eq([partial[:id]] * 3)
  end

  it "reports each node's summed time with its nested spans included, from the tracking start" do
    app = rails_stack(router do
      render(:template, "posts/index.html.erb") do
        2.times { render(:partial, "posts/_post.html.erb") { sleep 0.002 } }
      end
    end)

    app.call({})

    nodes = spans_of(posted.first[:payload])
    template = nodes.fetch("views/posts/index.html.erb")
    partial = nodes.fetch("views/posts/_post.html.erb")
    expect(partial[:total_ms]).to be >= 4.0
    expect(template[:total_ms]).to be >= partial[:total_ms]
    expect(partial[:start_ms]).to be >= template[:start_ms]
    expect(partial[:end_ms]).to be <= template[:end_ms]
    expect(partial[:end_ms] - partial[:start_ms]).to be >= partial[:total_ms] - 0.01
  end

  it "holds the payload until the outermost middleware returns and sends the middleware chain with it" do
    posted_during_session_commit = nil
    app = rails_stack(router { sql("SELECT 1") }, session_after: -> { posted_during_session_commit = posted.size })

    app.call({})

    expect(posted_during_session_commit).to eq(0)
    expect(posted.size).to eq(1)

    nodes = spans_of(posted.first[:payload])
    outer = nodes.fetch("ActionDispatch::HostAuthorization")
    session = nodes.fetch("ActionDispatch::Session::CookieStore")
    tracking = nodes.fetch("DeadBro::SqlTrackingMiddleware")
    routes = nodes.fetch("ActionDispatch::Routing::RouteSet")
    action = nodes.fetch("PostsController#index")

    expect(outer).to include(kind: "middleware", parent_id: nil, count: 1)
    expect(session[:parent_id]).to eq(outer[:id])
    expect(tracking[:parent_id]).to eq(session[:id])
    expect(routes).to include(kind: "endpoint", parent_id: tracking[:id])
    expect(outer[:start_ms]).to be < 0 # outside the tracking window, which starts in SqlTrackingMiddleware
    expect(outer[:end_ms]).to be >= action[:end_ms]
    expect(outer[:total_ms]).to be >= action[:total_ms]
  end

  it "sends the error payload once the exception has left the middleware chain" do
    app = rails_stack(router do
      sql("SELECT * FROM posts")
      raise ArgumentError, "bad page"
    end)

    expect { app.call({}) }.to raise_error(ArgumentError, "bad page")

    expect(posted.size).to eq(1)
    expect(posted.first[:event_name]).to eq("ArgumentError")
    payload = posted.first[:payload]
    expect(payload[:error]).to be true
    expect(spans_of(payload).keys).to include("ActionDispatch::HostAuthorization", "PostsController#index")
  end

  it "gives the exceptions app's own request no spans of the failed request" do
    # ShowExceptions sits outside DeadBro's middleware: it renders the error by
    # dispatching to an errors controller once the tracked part has returned.
    errors_controller = router(controller: "ErrorsController", action: "show")
    failing = DeadBro::SqlTrackingMiddleware.new(
      probe(router { sql("SELECT * FROM posts"); raise ArgumentError, "bad page" }, "ActionDispatch::Routing::RouteSet", described_class::ENDPOINT)
    )
    show_exceptions = lambda do |env|
      failing.call(env)
    rescue ArgumentError
      errors_controller.call(env)
    end

    probe(show_exceptions, "ActionDispatch::ShowExceptions").call({})

    expect(posted.map { |post| post[:event_name] }).to contain_exactly("ArgumentError", DeadBro::Subscriber::EVENT_NAME)
    error, errors_page = posted.partition { |post| post[:event_name] == "ArgumentError" }.map(&:first)
    expect(error[:payload][:spans].map { |node| node[:name] }).to include("PostsController#index", "ActionDispatch::ShowExceptions")
    expect(errors_page[:payload]).not_to have_key(:spans)
  end

  it "sends the payload right away, without middleware spans, when there is no middleware chain" do
    app = DeadBro::SqlTrackingMiddleware.new(router { sql("SELECT * FROM posts") })

    app.call({})

    expect(posted.size).to eq(1)
    kinds = posted.first[:payload][:spans].map { |node| node[:kind] }
    expect(kinds).to contain_exactly("action", "sql")
    expect(spans_of(posted.first[:payload]).fetch("PostsController#index")[:parent_id]).to be_nil
  end

  it "starts the next request's tree from scratch when a request isn't sent" do
    config.sample_rate = 0
    rails_stack(router { sql("SELECT * FROM posts") }).call({})
    expect(posted).to be_empty

    config.sample_rate = 100
    rails_stack(router { sql("SELECT * FROM posts") }).call({})
    rails_stack(router { sql("SELECT * FROM posts") }).call({})

    first, second = posted.map { |post| post[:payload][:spans].map { |node| [node[:id], node[:parent_id], node[:kind]] } }
    expect(second).to eq(first)
    # Middleware frames are numbered from 1, the other spans after MAX_RACK_FRAMES.
    expect(first.map(&:first).sort).to eq([1, 2, 3, 4, 201, 202])
  end

  it "records the DeadBro.watch block as a span around what runs inside it" do
    config.watch_enabled = true
    app = rails_stack(router do
      DeadBro.watch("load feed", source: "spec") { sql("SELECT * FROM feeds") }
    end)

    app.call({})

    payload = posted.first[:payload]
    nodes = spans_of(payload)
    watch = nodes.fetch("load feed")
    expect(watch).to include(kind: "watch", count: 1, parent_id: nodes.fetch("PostsController#index")[:id])
    expect(payload[:watch_events].first[:span_id]).to eq(watch[:id])
    feed_query = payload[:spans].find { |node| node[:kind] == "sql" }
    expect(feed_query[:parent_id]).to eq(watch[:id])
  end

  it "leaves an inline job's queries to the job's own payload" do
    app = rails_stack(router do
      sql("SELECT * FROM posts")
      # perform_now inside the action: the job's SQL tracking sits on top of the request's
      DeadBro::SqlSubscriber.start_request_tracking
      sql("SELECT * FROM jobs")
      DeadBro::SqlSubscriber.stop_request_tracking(wait_for_explains: false)
      DeadBro::SqlSubscriber.last_transaction_events
    end)

    app.call({})

    payload = posted.first[:payload]
    refs = payload[:spans].select { |node| node[:kind] == "sql" }.map { |node| node[:ref] }
    expect(refs).to eq([payload[:sql_queries].find { |q| q[:sql].include?("posts") }[:id]])
  end

  it "stops adding nodes past MAX_NODES and counts what it left out" do
    stub_const("DeadBro::SpanTracker::MAX_NODES", 3)
    app = rails_stack(router do
      render(:template, "posts/index.html.erb") do
        render(:partial, "posts/_a.html.erb") { sql("SELECT 1") }
        render(:partial, "posts/_b.html.erb") { sql("SELECT 2") }
      end
      sql("SELECT 3")
    end)

    app.call({})

    payload = posted.first[:payload]
    recorded = payload[:spans].reject { |node| %w[middleware endpoint].include?(node[:kind]) }
    expect(recorded.map { |node| node[:name] || node[:kind] }).to eq(["PostsController#index", "views/posts/index.html.erb", "views/posts/_a.html.erb"])
    expect(payload[:spans_dropped]).to eq(4)
    # Spans past the limit still leave their frames: what follows lands on the right parent.
    expect(recorded.last[:count]).to eq(1)
  end

  it "keeps the payload's spans and the next request's tree apart" do
    first_app = rails_stack(router { sql("SELECT * FROM posts") })
    first_app.call({})
    first_spans = posted.first[:payload][:spans]
    first_snapshot = first_spans.map(&:dup)

    rails_stack(router { sql("SELECT * FROM comments") }).call({})

    expect(first_spans).to eq(first_snapshot)
    expect(posted.last[:payload][:spans]).not_to equal(first_spans)
  end
end

RSpec.describe DeadBro::MiddlewareProbe do
  it "passes calls it doesn't handle on to the middleware" do
    inner = Class.new do
      def call(_env)
        [204, {}, []]
      end

      def mounted_path
        "/admin"
      end
    end.new
    probe = described_class.new(inner, "AdminMiddleware", DeadBro::SpanTracker::MIDDLEWARE)

    expect(probe.call({})).to eq([204, {}, []])
    expect(probe).to respond_to(:mounted_path)
    expect(probe.mounted_path).to eq("/admin")
  end

  it "wraps each middleware and the endpoint of a Rails middleware stack" do
    begin
      require "action_dispatch"
    rescue LoadError
      skip "actionpack isn't available in this bundle"
    end
    described_class.install!

    passthrough = Class.new do
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
    stub_const("RequestIdStub", Class.new(passthrough))
    stub_const("CookiesStub", Class.new(passthrough))
    stack = ActionDispatch::MiddlewareStack.new
    stack.use(RequestIdStub)
    stack.use(CookiesStub)
    endpoint = ->(_env) { [200, {}, ["ok"]] }

    app = stack.build(endpoint)

    # probe -> RequestIdStub -> probe -> CookiesStub -> probe -> endpoint
    names = []
    layer = app
    while layer.is_a?(described_class)
      names << layer.span_name
      wrapped = layer.instance_variable_get(:@app)
      break if wrapped.equal?(endpoint)

      layer = wrapped.instance_variable_get(:@app)
    end
    expect(names).to eq(%w[RequestIdStub CookiesStub Proc])
    expect(app.call({})).to eq([200, {}, ["ok"]])
  end
end
