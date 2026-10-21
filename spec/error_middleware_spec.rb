# frozen_string_literal: true

require "json"
require "rack"
require "spec_helper"
require "dead_bro/error_middleware"

# One error, one POST. The request subscriber reports an exception raised in a
# controller action; in production DebugExceptions then re-raises it past
# ErrorMiddleware, which used to send the same exception a second time.
# Requests that match no route (ActionController::RoutingError, nearly always
# bots) aren't sent unless the app opts in.
RSpec.describe DeadBro::ErrorMiddleware do
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

  let(:env) { Rack::MockRequest.env_for("/orders/42", "HTTP_USER_AGENT" => "Mozilla/5.0", "HTTP_HOST" => "Shop.Example.com:8443") }

  before do
    DeadBro.reset_configuration!
    config.enabled = true
    config.api_key = "test_key"
    config.sample_rate = 100
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    DeadBro::Subscriber.subscribe!(client: client)
  end

  after do
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  # What a Rails controller does: the action runs inside the process_action
  # notification, which puts the exception on the payload and re-raises it.
  def controller_action(controller: "OrdersController", &action)
    lambda do |rack_env|
      request = double("ActionDispatch::Request", env: rack_env, user_agent: "Mozilla/5.0", host: "shop.example.com")
      ActiveSupport::Notifications.instrument(
        DeadBro::Subscriber::EVENT_NAME,
        controller: controller, action: "show", format: "html", method: "GET", path: "/orders/42", status: 500, request: request
      ) { action.call }
    end
  end

  def events
    posted.map { |post| post["event"] }
  end

  it "sends an exception raised in a controller action once, from the request subscriber" do
    error = NoMethodError.new("undefined method 'total' for nil")
    middleware = described_class.new(controller_action { raise error }, client)

    expect { middleware.call(env) }.to raise_error(error)

    expect(events).to eq(["NoMethodError"])
    expect(posted.first["payload"]).to include("controller" => "OrdersController", "action" => "show", "error" => true)
    expect(env[DeadBro::Subscriber::REPORTED_ENV_KEY]).to be(true)
  end

  it "doesn't flag a request whose action didn't raise" do
    described_class.new(controller_action { :rendered }, client).call(env)

    expect(events).to eq([DeadBro::Subscriber::EVENT_NAME])
    expect(env).not_to have_key(DeadBro::Subscriber::REPORTED_ENV_KEY)
  end

  it "sends nothing for an exception raised in an excluded controller" do
    config.excluded_controllers = ["OrdersController"]
    middleware = described_class.new(controller_action { raise "boom" }, client)

    expect { middleware.call(env) }.to raise_error(RuntimeError, "boom")

    expect(posted).to be_empty
  end

  it "still sends an exception raised outside any controller action" do
    error = RuntimeError.new("session store unavailable")
    middleware = described_class.new(->(_env) { raise error }, client)

    expect { middleware.call(env) }.to raise_error(error)

    expect(events).to eq(["RuntimeError"])
    payload = posted.first["payload"]
    expect(payload["rack"]).to include("method" => "GET", "path" => "/orders/42")
    # What the backend needs to store the report as a request.
    expect(payload).to include("status" => 500, "host" => DeadBro.safe_hostname, "request_host" => "shop.example.com")
    expect(payload["duration_ms"]).to be >= 0
  end

  describe "ActionController::RoutingError" do
    let(:routing_error) { stub_const("ActionController::RoutingError", Class.new(StandardError)) }

    context "from a request that matches no route" do
      let(:not_found) { routing_error.new('No route matches [GET] "/wp-login.php"') }
      let(:middleware) { described_class.new(->(_env) { raise not_found }, client) }

      before do
        # Rails answers a RoutingError with a 404.
        stub_const("ActionDispatch::ExceptionWrapper", Class.new do
          def self.status_code_for_exception(class_name)
            (class_name == "ActionController::RoutingError") ? 404 : 500
          end
        end)
      end

      it "sends nothing by default" do
        expect { middleware.call(env) }.to raise_error(not_found)

        expect(posted).to be_empty
      end

      it "sends it, as a 404, once the app's settings turn report_routing_errors on" do
        config.apply_remote_settings("report_routing_errors" => true)

        expect { middleware.call(env) }.to raise_error(not_found)

        expect(events).to eq(["ActionController::RoutingError"])
        expect(posted.first["payload"]).to include("status" => 404)
      end
    end

    it "sends one raised by a controller action once, from the request subscriber" do
      middleware = described_class.new(controller_action { raise routing_error, "No order 42" }, client)

      expect { middleware.call(env) }.to raise_error(routing_error)

      expect(events).to eq(["ActionController::RoutingError"])
      expect(posted.first["payload"]).to include("controller" => "OrdersController")
    end
  end
end
