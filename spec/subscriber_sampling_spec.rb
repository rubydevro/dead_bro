# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Subscriber, "per-request-type sampling" do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    # Other specs (e.g. sql_subscriber_spec's start_explain_analyze_background tests)
    # can leak a stale pending-explain thread double into this thread-local.
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
  end

  after do
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
  end

  let(:captured_payloads) { [] }

  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
    allow(client).to receive(:post_heartbeat)
    client
  end

  def instrument(controller:, action:, exception: nil, exception_object: nil)
    ActiveSupport::Notifications.instrument(
      DeadBro::Subscriber::EVENT_NAME,
      controller: controller,
      action: action,
      format: "html",
      method: "GET",
      status: exception ? 500 : 200,
      exception: exception,
      exception_object: exception_object
    ) {}
  end

  it "samples out a request type whose override is 0, even with global sample_rate 100" do
    DeadBro.configuration.sample_rate = 100
    DeadBro.configuration.sample_rates_by_type = {"UsersController#index" => 0}

    described_class.subscribe!(client: stub_client)
    instrument(controller: "UsersController", action: "index")

    expect(captured_payloads).to be_empty
  end

  it "keeps sampling a request type whose override is 100, even with global sample_rate 0" do
    DeadBro.configuration.sample_rate = 0
    DeadBro.configuration.sample_rates_by_type = {"UsersController#index" => 100}

    described_class.subscribe!(client: stub_client)
    instrument(controller: "UsersController", action: "index")

    expect(captured_payloads.size).to eq(1)
  end

  it "falls back to the global sample_rate for request types with no override" do
    DeadBro.configuration.sample_rate = 0
    DeadBro.configuration.sample_rates_by_type = {"UsersController#index" => 100}

    described_class.subscribe!(client: stub_client)
    instrument(controller: "OtherController", action: "show")

    expect(captured_payloads).to be_empty
  end

  it "ships errors regardless of a 0 per-type override" do
    DeadBro.configuration.sample_rate = 100
    DeadBro.configuration.sample_rates_by_type = {"UsersController#index" => 0}

    described_class.subscribe!(client: stub_client)
    exception = StandardError.new("boom")
    exception.set_backtrace(["line1"])
    instrument(controller: "UsersController", action: "index", exception: ["StandardError", "boom"], exception_object: exception)

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.first[:force]).to be true
  end

  it "sends the normal (sampled-in) payload with force: true so client#post_metric does not re-roll the global rate" do
    DeadBro.configuration.sample_rate = 100
    DeadBro.configuration.sample_rates_by_type = {"UsersController#index" => 100}

    described_class.subscribe!(client: stub_client)
    instrument(controller: "UsersController", action: "index")

    expect(captured_payloads.size).to eq(1)
    expect(captured_payloads.first[:force]).to be true
  end
end
