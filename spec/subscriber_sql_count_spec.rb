# frozen_string_literal: true

require "securerandom"
require "spec_helper"

# sql_count used to be ActiveRecord::Base.connection.query_cache.size — the
# number of distinct cached SELECTs, capped at 100 since Rails 7.1 — so an N+1
# page that ran ~188 queries reported "SQL Count 100".
RSpec.describe DeadBro::Subscriber, "sql_count" do
  let(:captured_payloads) { [] }

  let(:stub_client) do
    client = instance_double(DeadBro::Client)
    allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
    allow(client).to receive(:post_heartbeat)
    client
  end

  def publish_sql(sql, name: "Season Count", cached: false)
    start = Time.now
    ActiveSupport::Notifications.publish("sql.active_record", start, start + 0.0001, SecureRandom.uuid, {
      sql: sql,
      name: name,
      cached: cached,
      connection_id: 1
    })
  end

  # The /admin/shows sample: one COUNT per show (N+1) plus a few page queries.
  def run_admin_shows_queries(shows: 184)
    publish_sql("SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = $1 LIMIT $2", name: "User Load")
    publish_sql("SELECT \"shows\".* FROM \"shows\" ORDER BY \"shows\".\"title\" ASC", name: "Show Load")
    publish_sql("SELECT COUNT(*) FROM \"shows\"", name: "Show Count")
    shows.times { |i| publish_sql("SELECT COUNT(*) FROM \"seasons\" WHERE \"seasons\".\"show_id\" = #{i + 1}") }
    publish_sql("SELECT \"settings\".* FROM \"settings\" LIMIT $1", name: "Setting Load")
  end

  before do
    DeadBro.reset_configuration!
    DeadBro.configuration.enabled = true
    DeadBro.configuration.sample_rate = 100
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    ActiveSupport::Notifications.unsubscribe(DeadBro::SqlSubscriber::SQL_EVENT_NAME)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
  end

  after do
    ActiveSupport::Notifications.unsubscribe(DeadBro::Subscriber::EVENT_NAME)
    ActiveSupport::Notifications.unsubscribe(DeadBro::SqlSubscriber::SQL_EVENT_NAME)
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_KEY] = nil
    Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
  end

  describe "request payload" do
    def instrument_request
      ActiveSupport::Notifications.instrument(
        DeadBro::Subscriber::EVENT_NAME,
        controller: "Admin::ShowsController",
        action: "index",
        format: "html",
        method: "GET",
        status: 200
      ) {}
    end

    before do
      DeadBro::SqlSubscriber.subscribe!
      described_class.subscribe!(client: stub_client)
      DeadBro::SqlSubscriber.start_request_tracking
    end

    it "counts every query, past the query cache's 100-entry cap" do
      run_admin_shows_queries
      instrument_request

      payload = captured_payloads.first[:payload]
      expect(payload[:sql_count]).to eq(188)
      expect(payload[:sql_cached_count]).to eq(0)
      season_count = payload[:sql_queries].find { |q| q[:name] == "Season Count" }
      expect(season_count[:count]).to eq(184)
      expect(season_count[:n_plus_one]).to be true
    end

    it "keeps counting after the raw query list stops at MAX_TRACKED_QUERIES" do
      run_admin_shows_queries(shows: DeadBro::SqlSubscriber::MAX_TRACKED_QUERIES + 200)
      instrument_request

      expect(captured_payloads.first[:payload][:sql_count]).to eq(DeadBro::SqlSubscriber::MAX_TRACKED_QUERIES + 204)
    end

    it "includes query-cache hits in sql_count and reports them in sql_cached_count" do
      publish_sql("SELECT \"shows\".* FROM \"shows\" WHERE \"shows\".\"id\" = $1 LIMIT $2", name: "Show Load")
      3.times { publish_sql("SELECT \"shows\".* FROM \"shows\" WHERE \"shows\".\"id\" = $1 LIMIT $2", name: "Show Load", cached: true) }
      instrument_request

      payload = captured_payloads.first[:payload]
      expect(payload[:sql_count]).to eq(4)
      expect(payload[:sql_cached_count]).to eq(3)
    end

    it "leaves out SCHEMA queries and transaction control, like Rails' own queries_count" do
      publish_sql("SELECT a.attname FROM pg_attribute a", name: "SCHEMA")
      publish_sql("BEGIN", name: "TRANSACTION")
      publish_sql("UPDATE \"shows\" SET \"title\" = $1 WHERE \"shows\".\"id\" = $2", name: "Show Update")
      publish_sql("COMMIT", name: "TRANSACTION")
      instrument_request

      expect(captured_payloads.first[:payload][:sql_count]).to eq(1)
    end

    it "reports 0 for a request without SQL and never asks ActiveRecord for a connection" do
      active_record_base = Class.new do
        def self.connection
          raise "sql_count must not lease a DB connection"
        end
      end
      stub_const("ActiveRecord::Base", active_record_base)
      allow(active_record_base).to receive(:connection).and_call_original

      instrument_request

      payload = captured_payloads.first[:payload]
      expect(payload[:sql_count]).to eq(0)
      expect(payload[:sql_cached_count]).to eq(0)
      expect(active_record_base).not_to have_received(:connection)
    end

    it "sends the same counts on an errored request" do
      run_admin_shows_queries
      exception = StandardError.new("boom")
      exception.set_backtrace(["app/controllers/admin/shows_controller.rb:5:in `index'"])
      ActiveSupport::Notifications.instrument(
        DeadBro::Subscriber::EVENT_NAME,
        controller: "Admin::ShowsController", action: "index", format: "html", method: "GET", status: 500,
        exception: ["StandardError", "boom"], exception_object: exception
      ) {}

      payload = captured_payloads.first[:payload]
      expect(payload[:error]).to be true
      expect(payload[:sql_count]).to eq(188)
    end
  end

  describe "job payload" do
    let(:mock_job) do
      job_class = double("JobClass", name: "ShowsImportJob")
      job = double("Job", job_id: "abc-123", queue_name: "default", arguments: [], enqueued_at: nil)
      allow(job).to receive(:class).and_return(job_class)
      job
    end

    after do
      ActiveSupport::Notifications.unsubscribe("perform.active_job")
      ActiveSupport::Notifications.unsubscribe("perform_start.active_job")
      Thread.current[DeadBro::LightweightMemoryTracker::THREAD_LOCAL_KEY] = nil
    end

    it "sends sql_count and sql_cached_count for jobs too" do
      DeadBro::SqlSubscriber.subscribe!
      DeadBro::JobSubscriber.subscribe!(client: stub_client)
      DeadBro::SqlSubscriber.start_request_tracking

      run_admin_shows_queries
      publish_sql("SELECT \"settings\".* FROM \"settings\" LIMIT $1", name: "Setting Load", cached: true)
      ActiveSupport::Notifications.instrument("perform.active_job", job: mock_job) {}

      payload = captured_payloads.first[:payload]
      expect(payload[:sql_count]).to eq(189)
      expect(payload[:sql_cached_count]).to eq(1)
    end
  end

  describe ".sql_count / .sql_cached_count" do
    it "is 0 without aggregates" do
      expect(described_class.sql_count(nil)).to eq(0)
      expect(described_class.sql_count([])).to eq(0)
      expect(described_class.sql_cached_count(nil)).to eq(0)
    end

    it "sums the aggregate counts" do
      aggregates = [{count: 184, cached_count: 0}, {count: 4, cached_count: 3}]
      expect(described_class.sql_count(aggregates)).to eq(188)
      expect(described_class.sql_cached_count(aggregates)).to eq(3)
    end
  end
end
