# frozen_string_literal: true

require "securerandom"
require "spec_helper"

RSpec.describe DeadBro::SqlSubscriber do
  let(:sql_subscriber) { DeadBro::SqlSubscriber }

  before do
    # Clear any existing subscriptions
    if defined?(ActiveSupport::Notifications)
      ActiveSupport::Notifications.unsubscribe("sql.active_record")
    end
  end

  after do
    # Clean up subscriptions
    if defined?(ActiveSupport::Notifications)
      ActiveSupport::Notifications.unsubscribe("sql.active_record")
    end
  end

  it "can sanitize SQL queries" do
    sensitive_sql = "SELECT * FROM users WHERE password = 'secret123' AND email = 'test@example.com'"
    sanitized = sql_subscriber.sanitize_sql(sensitive_sql)

    expect(sanitized).to include("password = ?")
    # The email sanitization might not work the same way, but password should be sanitized
    expect(sanitized).not_to include("secret123")
  end

  it "limits query length" do
    long_sql = "SELECT " + "a" * 2000
    sanitized = sql_subscriber.sanitize_sql(long_sql)

    expect(sanitized.length).to be <= 1004 # 1000 + "..."
    expect(sanitized).to end_with("...")
  end

  it "tracks SQL queries during request processing" do
    skip unless defined?(ActiveSupport::Notifications)
    
    sql_subscriber.subscribe!

    # Start request tracking
    sql_subscriber.start_request_tracking

    # Simulate SQL queries using instrument with proper timing
    start1 = Time.now
    finish1 = start1 + 0.001
    ActiveSupport::Notifications.publish("sql.active_record", start1, finish1, SecureRandom.uuid, {
      sql: "SELECT * FROM users",
      name: "User Load",
      cached: false,
      connection_id: 123
    })

    start2 = Time.now
    finish2 = start2 + 0.002
    ActiveSupport::Notifications.publish("sql.active_record", start2, finish2, SecureRandom.uuid, {
      sql: "UPDATE users SET last_login = NOW()",
      name: "User Update",
      cached: false,
      connection_id: 123
    })

    # Give notifications time to process
    sleep(0.1)

    # Get tracked queries
    queries = sql_subscriber.stop_request_tracking

    expect(queries.length).to eq(2)
    expect(queries.first[:sql]).to eq("SELECT * FROM users")
    expect(queries.first[:name]).to eq("User Load")
    expect(queries.first[:cached]).to be false
    expect(queries.first[:connection_id]).to eq(123)
    expect(queries.first[:duration_ms]).to be_a(Numeric)
  end

  it "tracks all queries during request processing" do
    skip unless defined?(ActiveSupport::Notifications)
    
    sql_subscriber.subscribe!
    sql_subscriber.start_request_tracking

    # Simulate multiple queries
    5.times do |i|
      start = Time.now
      finish = start + 0.001
      ActiveSupport::Notifications.publish("sql.active_record", start, finish, SecureRandom.uuid, {
        sql: "SELECT * FROM table#{i}",
        name: "Query #{i}",
        cached: false,
        connection_id: 123
      })
    end

    # Give notifications time to process
    sleep(0.1)

    queries = sql_subscriber.stop_request_tracking
    expect(queries.length).to eq(5)
    # Should track all queries
    expect(queries.map { |q| q[:sql] }).to include("SELECT * FROM table0")
    expect(queries.map { |q| q[:sql] }).to include("SELECT * FROM table4")
  end

  it "ignores SCHEMA queries" do
    skip unless defined?(ActiveSupport::Notifications)
    
    sql_subscriber.subscribe!
    sql_subscriber.start_request_tracking

    # SCHEMA queries should be ignored
    start1 = Time.now
    finish1 = start1 + 0.001
    ActiveSupport::Notifications.publish("sql.active_record", start1, finish1, SecureRandom.uuid, {
      sql: "SELECT * FROM schema_migrations",
      name: "SCHEMA",
      cached: false,
      connection_id: 123
    })

    # Regular query should be tracked
    start2 = Time.now
    finish2 = start2 + 0.001
    ActiveSupport::Notifications.publish("sql.active_record", start2, finish2, SecureRandom.uuid, {
      sql: "SELECT * FROM users",
      name: "User Load",
      cached: false,
      connection_id: 123
    })

    # Give notifications time to process
    sleep(0.1)

    queries = sql_subscriber.stop_request_tracking
    expect(queries.length).to eq(1)
    expect(queries.first[:name]).to eq("User Load")
  end

  it "handles start_request_tracking and stop_request_tracking" do
    sql_subscriber.start_request_tracking
    expect(Thread.current[:dead_bro_sql_queries]).to be_a(Array)

    queries = sql_subscriber.stop_request_tracking
    expect(queries).to be_a(Array)
    expect(Thread.current[:dead_bro_sql_queries]).to be_nil
  end

  it "has configuration for slow query threshold and explain analyze" do
    config = DeadBro::Configuration.new
    expect(config.slow_query_threshold_ms).to eq(500)
    expect(config.explain_analyze_enabled).to be false
    
    # Test configuration
    config.slow_query_threshold_ms = 1000
    config.explain_analyze_enabled = true
    expect(config.slow_query_threshold_ms).to eq(1000)
    expect(config.explain_analyze_enabled).to be true
  end

  it "determines if query should be explained" do
    DeadBro.configuration.explain_analyze_enabled = true
    # Fast query should not be explained
    expect(sql_subscriber.should_explain_query?(100, "SELECT * FROM users")).to be false
    
    # Slow query should be explained
    expect(sql_subscriber.should_explain_query?(600, "SELECT * FROM users")).to be true
    
    # EXPLAIN queries should not be explained
    expect(sql_subscriber.should_explain_query?(600, "EXPLAIN SELECT * FROM users")).to be false
    
    # Empty queries should not be explained
    expect(sql_subscriber.should_explain_query?(600, "")).to be false
    
    # Transaction queries should not be explained
    expect(sql_subscriber.should_explain_query?(600, "BEGIN")).to be false
    expect(sql_subscriber.should_explain_query?(600, "COMMIT")).to be false
  end
end

