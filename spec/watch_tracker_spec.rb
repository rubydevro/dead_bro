# frozen_string_literal: true

require "securerandom"
require "spec_helper"

RSpec.describe DeadBro::WatchTracker do
  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.watch_enabled = true
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now - 0.05
  end

  after do
    described_class.stop_request_tracking
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  def start_tracking
    DeadBro::SqlSubscriber.start_request_tracking if defined?(DeadBro::SqlSubscriber)
    described_class.start_request_tracking
  end

  it "yields without recording when watch is disabled" do
    DeadBro.configuration.watch_enabled = false
    start_tracking
    called = false

    result = DeadBro.watch("ignored") do
      called = true
      :ok
    end

    expect(called).to be true
    expect(result).to eq(:ok)
    expect(described_class.stop_request_tracking).to eq([])
  end

  it "yields without recording when tracking is not active" do
    called = false
    DeadBro.watch("ignored") { called = true }
    expect(called).to be true
  end

  it "records elapsed time and start offset for a block" do
    start_tracking

    DeadBro.watch("load users") { sleep 0.01 }

    events = described_class.stop_request_tracking
    expect(events.length).to eq(1)
    expect(events.first[:label]).to eq("load users")
    expect(events.first[:duration_ms]).to be >= 5.0
    expect(events.first[:start_offset_ms]).to be_a(Numeric)
    expect(events.first[:depth]).to eq(0)
    expect(events.first[:sql_count]).to eq(0)
    expect(events.first[:error]).to be false
  end

  it "records nested spans with increasing depth" do
    start_tracking

    DeadBro.watch("outer") do
      DeadBro.watch("inner") { nil }
    end

    events = described_class.stop_request_tracking
    expect(events.map { |e| [e[:label], e[:depth]] }).to eq([
      ["outer", 0],
      ["inner", 1]
    ])
  end

  it "records exception metadata and re-raises" do
    start_tracking
    error = Class.new(StandardError)

    expect do
      DeadBro.watch("risky") { raise error, "boom" }
    end.to raise_error(error, "boom")

    events = described_class.stop_request_tracking
    expect(events.length).to eq(1)
    expect(events.first[:error]).to be true
    expect(events.first[:exception_class]).to eq(error.name)
  end

  it "attributes SQL executed inside the block" do
    skip unless defined?(ActiveSupport::Notifications)

    DeadBro::SqlSubscriber.subscribe!
    start_tracking

    DeadBro.watch("query block") do
      start = Time.now
      finish = start + 0.001
      ActiveSupport::Notifications.publish("sql.active_record", start, finish, SecureRandom.uuid, {
        sql: "SELECT * FROM users",
        name: "User Load",
        cached: false,
        connection_id: 1
      })
    end

    events = described_class.stop_request_tracking
    expect(events.first[:sql_count]).to eq(1)
    expect(events.first[:sql_duration_ms]).to be >= 0.0
  ensure
    ActiveSupport::Notifications.unsubscribe("sql.active_record") if defined?(ActiveSupport::Notifications)
  end

  it "truncates long labels" do
    start_tracking
    long_label = "x" * 300

    DeadBro.watch(long_label) { nil }

    events = described_class.stop_request_tracking
    expect(events.first[:label].length).to be <= described_class::MAX_LABEL_LENGTH + 3
  end

  it "stops recording when max spans per request is reached" do
    start_tracking
    stub_const("DeadBro::WatchTracker::MAX_SPANS_PER_REQUEST", 2)

    3.times { |i| DeadBro.watch("span #{i}") { nil } }

    events = described_class.stop_request_tracking
    expect(events.length).to eq(2)
  end

  it "does not record spans beyond max depth but still yields" do
    start_tracking
    stub_const("DeadBro::WatchTracker::MAX_DEPTH", 1)
    deepest = nil

    DeadBro.watch("depth 0") do
      DeadBro.watch("depth 1") do
        DeadBro.watch("too deep") { deepest = :ran }
      end
    end

    expect(deepest).to eq(:ran)
    events = described_class.stop_request_tracking
    expect(events.map { |e| e[:label] }).to eq(["depth 0", "depth 1"])
  end

  it "stores sanitized tags on the span" do
    start_tracking

    DeadBro.watch("tagged", customer_id: 42, note: "hello") { nil }

    events = described_class.stop_request_tracking
    expect(events.first[:tags]).to eq({"customer_id" => "42", "note" => "hello"})
  end
end
