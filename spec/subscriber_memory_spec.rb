# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Subscriber, "memory leak sampling" do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    DeadBro.configuration.sample_rate = 100
    DeadBro.configuration.memory_tracking_enabled = true
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
    allow(DeadBro::MemoryLeakDetector).to receive(:record_memory_sample)
  end

  after do
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
  end

  let(:captured_payloads) { [] }

  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
    allow(client).to receive(:post_heartbeat)
    client
  end

  def instrument_request
    ActiveSupport::Notifications.instrument(
      DeadBro::Subscriber::EVENT_NAME,
      controller: "UsersController", action: "index", format: "html", method: "GET", status: 200
    ) {}
  end

  it "includes heap_live_slots in gc_stats" do
    expect(described_class.gc_stats[:heap_live_slots]).to be > 0
  end

  it "records the live heap slot count in the leak-detection sample, not 0" do
    described_class.subscribe!(client: stub_client)
    instrument_request

    expect(DeadBro::MemoryLeakDetector).to have_received(:record_memory_sample)
      .with(hash_including(object_count: a_value > 0))
  end

  it "ships heap_live_slots in the payload's gc_stats" do
    described_class.subscribe!(client: stub_client)
    instrument_request

    expect(captured_payloads.first[:payload][:gc_stats][:heap_live_slots]).to be > 0
  end
end
