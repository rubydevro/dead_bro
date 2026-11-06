# frozen_string_literal: true

require "json"
require "rack"
require "spec_helper"
require "dead_bro/error_middleware"

# What an app hides from its own logs with config.filter_parameters stays out
# of DeadBro too. Controller payloads carry Rails' request.filtered_parameters;
# job arguments and what ErrorMiddleware reads from the Rack request only went
# through DeadBro's own list of sensitive keys, so a job's phone number or an
# email address in a query string reached DeadBro in plain text.
RSpec.describe "Parameter filtering" do
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

  before do
    DeadBro.reset_configuration!
    config.enabled = true
    config.api_key = "test_key"
    config.sample_rate = 100
    hide_const("Rails")
  end

  after do
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_TXN_EVENTS_KEY] = nil
    Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  # A Rails app whose config/initializers/filter_parameter_logging.rb lists
  # filters. The request subscriber also reads Rails.cache.
  def app_filter_parameters(filters)
    app_config = double("Rails::Application::Configuration", filter_parameters: filters)
    stub_const("Rails", double("Rails", application: double("Rails::Application", config: app_config), cache: nil))
  end

  describe "DeadBro.parameter_filter" do
    it "is built from the app's filter_parameters" do
      app_filter_parameters([:phone])

      expect(DeadBro.parameter_filter.filter("phone" => "+1 555 0142", "city" => "Lisbon"))
        .to eq("phone" => "[FILTERED]", "city" => "Lisbon")
    end

    it "is built from the list it's given instead" do
      app_filter_parameters([:phone])

      expect(DeadBro.parameter_filter([:city]).filter("phone" => "+1 555 0142", "city" => "Lisbon"))
        .to eq("phone" => "+1 555 0142", "city" => "[FILTERED]")
    end

    it "is nil outside Rails" do
      expect(DeadBro.parameter_filter).to be_nil
    end

    it "is nil when the app filters nothing" do
      app_filter_parameters([])

      expect(DeadBro.parameter_filter).to be_nil
    end

    it "is kept until the app's list changes" do
      filters = [:phone]
      app_filter_parameters(filters)
      first = DeadBro.parameter_filter

      expect(DeadBro.parameter_filter).to be(first)

      filters << :body

      expect(DeadBro.parameter_filter).not_to be(first)
      expect(DeadBro.parameter_filter.filter("body" => "See you at 8")).to eq("body" => "[FILTERED]")
    end
  end

  describe "job arguments" do
    let(:job_class) { double("JobClass", name: "SmsReplyJob") }

    before do
      ActiveSupport::Notifications.unsubscribe(DeadBro::JobSubscriber::JOB_EVENT_NAME)
      DeadBro::JobSubscriber.subscribe!(client: client)
    end

    after { ActiveSupport::Notifications.unsubscribe(DeadBro::JobSubscriber::JOB_EVENT_NAME) }

    # Runs a job with these arguments and returns the arguments DeadBro received.
    def perform(arguments, job_class: self.job_class)
      job = double("Job", job_id: "job-1", queue_name: "default", arguments: arguments, enqueued_at: nil)
      allow(job).to receive(:class).and_return(job_class)
      ActiveSupport::Notifications.instrument(DeadBro::JobSubscriber::JOB_EVENT_NAME, job: job) {}

      expect(posted.size).to eq(1)
      posted.first["payload"]["arguments"]
    end

    it "hides keyword arguments the app's filter_parameters name, at any depth" do
      # Rails' default list, plus the app's own personal data.
      app_filter_parameters([:passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :phone, :body])

      arguments = perform([{from_phone: "+1 555 0142", body: "See you at 8", reply: {email: "dana@example.com", channel: "sms"}}])

      expect(arguments).to eq([{"from_phone" => "[FILTERED]", "body" => "[FILTERED]", "reply" => {"email" => "[FILTERED]", "channel" => "sms"}}])
    end

    it "hides the keys request params hide, nested and inside arrays too, without filter_parameters" do
      arguments = perform([
        {account_id: 7, access_token: "tok-made-up-1", user: {password: "correct horse"}},
        [{api_key: "made-up-key", label: "primary"}]
      ])

      expect(arguments).to eq([
        {"account_id" => 7, "access_token" => "[FILTERED]", "user" => {"password" => "[FILTERED]"}},
        [{"api_key" => "[FILTERED]", "label" => "primary"}]
      ])
    end

    it "still hides a bare key argument" do
      expect(perform([{key: "made-up-key", region: "eu-west-1"}])).to eq([{"key" => "[FILTERED]", "region" => "eu-west-1"}])
    end

    it "sends each argument as [FILTERED] for a job class that keeps its arguments out of the logs" do
      quiet_job = double("JobClass", name: "ImportContactsJob", log_arguments?: false)

      expect(perform(["contacts.csv", {owner_email: "dana@example.com"}], job_class: quiet_job)).to eq(["[FILTERED]", "[FILTERED]"])
    end

    it "sends the arguments of a job class that logs them" do
      logged_job = double("JobClass", name: "ImportContactsJob", log_arguments?: true)

      expect(perform(["contacts.csv"], job_class: logged_job)).to eq(["contacts.csv"])
    end

    it "sends no arguments rather than unfiltered ones when the app's filter can't be built" do
      allow(DeadBro).to receive(:parameter_filter).and_raise(RegexpError)

      expect(perform([{from_phone: "+1 555 0142"}])).to eq([])
    end

    it "keeps an Integer argument in an app without ActiveRecord" do
      hide_const("ActiveRecord")

      expect(perform([42, "full"])).to eq(["42", "full"])
    end
  end

  # A request's params arrive filtered by Rails and then go through DeadBro's
  # own list. Its path should hide the same values, but on Rails 6.1 and 7.0
  # the payload's path is the raw request.fullpath, and on no version did
  # DeadBro's own list reach the query string.
  describe "request path" do
    before do
      ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
      DeadBro::Subscriber.subscribe!(client: client)
    end

    after { ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME) }

    # Runs a controller action and returns the payload DeadBro received. path
    # and params are what Rails puts in the payload: request.fullpath (7.1+:
    # request.filtered_path) and request.filtered_parameters.
    def process_action(path:, params:, request: nil)
      ActiveSupport::Notifications.instrument(
        DeadBro::Subscriber::EVENT_NAME,
        controller: "PasswordResetsController", action: "edit", format: "html", method: "GET",
        status: 200, path: path, params: params, request: request
      ) {}

      expect(posted.size).to eq(1)
      posted.first["payload"]
    end

    # The request Rails 6.1+ puts in the payload.
    def request_with_filtered_path(filtered_path)
      double("ActionDispatch::Request", filtered_path: filtered_path, env: {}, user_agent: "Mozilla/5.0", host: "shop.example.com")
    end

    it "takes the path Rails filtered, not the raw fullpath Rails 6.1 and 7.0 put in the payload" do
      payload = process_action(
        path: "/callbacks/sms?phone=%2B15550142&status=delivered",
        params: {"phone" => "[FILTERED]", "status" => "delivered"},
        request: request_with_filtered_path("/callbacks/sms?phone=[FILTERED]&status=delivered")
      )

      expect(payload["path"]).to eq("/callbacks/sms?phone=[FILTERED]&status=delivered")
    end

    # An app whose filter_parameters is still Rails 6's [:password]: Rails
    # leaves the token in both, DeadBro's own list hides it in both.
    it "hides in the path what the params hide" do
      payload = process_action(
        path: "/password/reset?token=made-up-token&step=2",
        params: {"token" => "made-up-token", "step" => "2"},
        request: request_with_filtered_path("/password/reset?token=made-up-token&step=2")
      )

      expect(payload["params"]).to eq("token" => "[FILTERED]", "step" => "2")
      expect(payload["path"]).to eq("/password/reset?token=[FILTERED]&step=2")
    end

    it "filters the raw path with the app's filter_parameters on Rails 6.0, which doesn't pass the request" do
      app_filter_parameters([:phone])

      payload = process_action(
        path: "/callbacks/sms?phone=%2B15550142&status=delivered",
        params: {"phone" => "[FILTERED]", "status" => "delivered"}
      )

      expect(payload["path"]).to eq("/callbacks/sms?phone=[FILTERED]&status=delivered")
    end

    it "keeps a query string whose values, not names, hold a sensitive word" do
      path = "/search?q=password+manager&page=2"

      payload = process_action(path: path, params: {"q" => "password manager", "page" => "2"}, request: request_with_filtered_path(path))

      expect(payload["path"]).to eq(path)
    end

    it "keeps a path without a query string as it is" do
      payload = process_action(path: "/orders/42", params: {"id" => "42"}, request: request_with_filtered_path("/orders/42"))

      expect(payload["path"]).to eq("/orders/42")
    end

    it "sends an empty path rather than an unfiltered one when filtering fails" do
      allow(DeadBro::Subscriber).to receive(:filter_url).and_raise(ArgumentError)

      payload = process_action(
        path: "/callbacks/sms?phone=%2B15550142",
        params: {},
        request: request_with_filtered_path("/callbacks/sms?phone=%2B15550142")
      )

      expect(payload["path"]).to eq("")
    end
  end

  describe DeadBro::ErrorMiddleware do
    let(:error) { RuntimeError.new("SMS provider timed out") }
    let(:app) { ->(_env) { raise error } }

    # Sends a request whose handling raises and returns the rack section of the report.
    def report(uri, **opts)
      env = Rack::MockRequest.env_for(uri, opts)

      expect { described_class.new(app, client).call(env) }.to raise_error(error)

      expect(posted.size).to eq(1)
      posted.first["payload"]["rack"]
    end

    it "hides params and query string values the request's parameter filter names" do
      rack = report(
        "/callbacks/sms?phone=%2B15550142&status=delivered",
        :method => "POST", :params => {"body" => "See you at 8", "carrier" => "acme"},
        "action_dispatch.parameter_filter" => [:phone, :body]
      )

      expect(rack["params"]).to eq("phone" => "[FILTERED]", "status" => "delivered", "body" => "[FILTERED]", "carrier" => "acme")
      expect(rack["fullpath"]).to eq("/callbacks/sms?phone=[FILTERED]&status=delivered")
    end

    it "uses the app's filter_parameters when the request carries none" do
      app_filter_parameters([:phone])

      rack = report("/callbacks/sms?phone=%2B15550142&status=delivered")

      expect(rack["params"]).to eq("phone" => "[FILTERED]", "status" => "delivered")
      expect(rack["fullpath"]).to eq("/callbacks/sms?phone=[FILTERED]&status=delivered")
    end

    it "hides the keys DeadBro always hides in the query string too" do
      rack = report("/password/reset?token=made-up-token&user%5Bpassword%5D=correct+horse&step=2")

      expect(rack["params"]).to eq("token" => "[FILTERED]", "user" => {"password" => "[FILTERED]"}, "step" => "2")
      expect(rack["fullpath"]).to eq("/password/reset?token=[FILTERED]&user%5Bpassword%5D=[FILTERED]&step=2")
    end

    it "filters the referer's query string" do
      rack = report(
        "/orders",
        "HTTP_REFERER" => "https://shop.example.com/checkout?email=dana%40example.com&step=2",
        "action_dispatch.parameter_filter" => [:email]
      )

      expect(rack["referer"]).to eq("https://shop.example.com/checkout?email=[FILTERED]&step=2")
    end

    it "keeps a query string with nothing to hide as it was sent" do
      rack = report("/orders?page=2&sort=created_at&q=caf%C3%A9", "action_dispatch.parameter_filter" => [:email])

      expect(rack["fullpath"]).to eq("/orders?page=2&sort=created_at&q=caf%C3%A9")
    end

    it "sends no query string rather than an unfiltered one when filtering it fails" do
      allow(DeadBro::Subscriber).to receive(:filter_url).and_raise(ArgumentError)

      rack = report("/callbacks/sms?phone=%2B15550142")

      expect(rack["fullpath"]).to be_nil
      expect(rack["path"]).to eq("/callbacks/sms")
    end
  end
end
