# frozen_string_literal: true

require "securerandom"
require "spec_helper"

RSpec.describe "DeadBro.watch integration" do
  let(:client) { instance_double(DeadBro::Client, post_metric: true, post_heartbeat: false) }

  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.watch_enabled = true
    DeadBro.configuration.enabled = true
    DeadBro.configuration.sample_rate = 100
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now - 0.01
    DeadBro::SqlSubscriber.start_request_tracking
    DeadBro::WatchTracker.start_request_tracking
  end

  after do
    DeadBro::WatchTracker.stop_request_tracking
    DeadBro::SqlSubscriber.stop_request_tracking
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  it "includes watch_events in the request payload assembled like Subscriber" do
    skip unless defined?(ActiveSupport::Notifications)

    DeadBro::SqlSubscriber.subscribe!

    DeadBro.watch("sync users") do
      start = Time.now
      finish = start + 0.001
      ActiveSupport::Notifications.publish("sql.active_record", start, finish, SecureRandom.uuid, {
        sql: "SELECT * FROM users WHERE active = true",
        name: "User Load",
        cached: false,
        connection_id: 1
      })
    end

    watch_events = DeadBro::WatchTracker.stop_request_tracking
    sql_queries = DeadBro::SqlSubscriber.stop_request_tracking

    payload = {
      controller: "UsersController",
      action: "index",
      duration_ms: 25.0,
      sql_queries: sql_queries,
      watch_events: watch_events
    }

    expect(payload[:watch_events].length).to eq(1)
    span = payload[:watch_events].first
    expect(span[:label]).to eq("sync users")
    expect(span[:sql_count]).to eq(1)
    expect(span[:start_offset_ms]).to be_a(Numeric)
    expect(payload[:sql_queries]).not_to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe("sql.active_record") if defined?(ActiveSupport::Notifications)
  end

  it "simulates a background job lifecycle with nested watch blocks" do
    DeadBro.watch("job setup") do
      DeadBro.watch("load records") { sleep 0.005 }
    end

    watch_events = DeadBro::WatchTracker.stop_request_tracking

    expect(watch_events.length).to eq(2)
    expect(watch_events.first[:depth]).to eq(0)
    expect(watch_events.last[:depth]).to eq(1)
    expect(watch_events.all? { |e| e.key?(:duration_ms) }).to be true
  end
end
