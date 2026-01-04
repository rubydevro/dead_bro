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

  describe ".interpolate_sql_with_binds" do
    let(:connection) { double("Connection") }

    before do
      allow(connection).to receive(:quote) { |val| "'#{val}'" }
    end

    it "interpolates $N style placeholders (PostgreSQL)" do
      sql = "SELECT * FROM users WHERE id = $1 AND name = $2"
      binds = [1, "test"]

      interpolated = sql_subscriber.interpolate_sql_with_binds(sql, binds, connection)
      expect(interpolated).to eq("SELECT * FROM users WHERE id = '1' AND name = 'test'")
    end

    it "interpolates ? style placeholders (MySQL/SQLite)" do
      sql = "SELECT * FROM users WHERE id = ? AND name = ?"
      binds = [1, "test"]

      interpolated = sql_subscriber.interpolate_sql_with_binds(sql, binds, connection)
      expect(interpolated).to eq("SELECT * FROM users WHERE id = '1' AND name = 'test'")
    end

    it "handles ActiveRecord QueryAttribute objects" do
      sql = "SELECT * FROM users WHERE id = $1"
      
      # Mock QueryAttribute if it doesn't exist in standard env, but usually we just need an object responding to value_for_database
      attr = double("QueryAttribute", value_for_database: 123)
      binds = [attr]

      interpolated = sql_subscriber.interpolate_sql_with_binds(sql, binds, connection)
      expect(interpolated).to eq("SELECT * FROM users WHERE id = '123'")
    end

    it "returns original sql if binds are empty" do
      sql = "SELECT * FROM users"
      expect(sql_subscriber.interpolate_sql_with_binds(sql, [], connection)).to eq(sql)
      expect(sql_subscriber.interpolate_sql_with_binds(sql, nil, connection)).to eq(sql)
    end
  end

  describe ".safe_query_trace" do
    it "builds trace from filename/line/method" do
      data = {
        filename: "app/models/user.rb",
        line: 10,
        method: "find_by_email"
      }
      
      trace = sql_subscriber.safe_query_trace(data)
      expect(trace).to include("app/models/user.rb:10:in `find_by_email'")
    end

    it "filters sensitive information from paths" do
      data = {
        filename: "app/services/reset_password_token/validator.rb",
        line: 5,
        method: "validate"
      }
      
      # Should filter 'token'
      trace = sql_subscriber.safe_query_trace(data)
      expect(trace.first).to include("/[FILTERED]/")
      expect(trace.first).not_to include("token")
    end

    it "uses captured backtrace if available" do
      captured_backtrace = [
        "/gems/activerecord/lib/base.rb:100",
        "app/controllers/users_controller.rb:20:in `index'",
        "app/middleware/auth.rb:15:in `call'"
      ]
      
      trace = sql_subscriber.safe_query_trace({}, captured_backtrace)
      # Should include app frames
      expect(trace).to include("app/controllers/users_controller.rb:20:in `index'")
      # Should filter vendor/gem frames
      expect(trace).not_to include("/gems/activerecord/lib/base.rb:100")
    end
  end

  describe ".format_explain_result" do
    let(:connection) { double("Connection") }

    context "for PostgreSQL" do
      before { allow(connection).to receive(:adapter_name).and_return("PostgreSQL") }

      it "formats ActiveRecord::Result with rows" do
        # PG returns ActiveRecord::Result
        result = double("ActiveRecord::Result", rows: [["Seq Scan on users"], ["  Filter: (id = 1)"]])
        
        formatted = sql_subscriber.format_explain_result(result, connection)
        expect(formatted).to include("Seq Scan on users")
        expect(formatted).to include("Filter: (id = 1)")
      end
    end

    context "for MySQL" do
      before { allow(connection).to receive(:adapter_name).and_return("Mysql2") }

      it "formats Array of Hashes" do
        result = [
          { "id" => 1, "select_type" => "SIMPLE", "table" => "users", "type" => "const" }
        ]
        
        formatted = sql_subscriber.format_explain_result(result, connection)
        expect(formatted).to include("SIMPLE")
        expect(formatted).to include("const")
      end
    end

    context "for SQLite" do
      before { allow(connection).to receive(:adapter_name).and_return("SQLite3") }

      it "formats Array of Hashes" do
        result = [
          { "id" => 2, "parent" => 0, "detail" => "SCAN TABLE users" }
        ]
        
        formatted = sql_subscriber.format_explain_result(result, connection)
        expect(formatted).to include("SCAN TABLE users")
      end
    end
  end

  describe ".build_explain_query" do
    let(:connection) { double("Connection") }

    it "uses EXPLAIN (ANALYZE, BUFFERS) for PostgreSQL" do
      allow(connection).to receive(:adapter_name).and_return("PostgreSQL")
      sql = "SELECT * FROM users"
      expect(sql_subscriber.build_explain_query(sql, connection)).to eq("EXPLAIN (ANALYZE, BUFFERS) #{sql}")
    end

    it "uses EXPLAIN ANALYZE for MySQL" do
      allow(connection).to receive(:adapter_name).and_return("Mysql2")
      sql = "SELECT * FROM users"
      expect(sql_subscriber.build_explain_query(sql, connection)).to eq("EXPLAIN ANALYZE #{sql}")
    end

    it "uses EXPLAIN QUERY PLAN for SQLite" do
      allow(connection).to receive(:adapter_name).and_return("SQLite3")
      sql = "SELECT * FROM users"
      expect(sql_subscriber.build_explain_query(sql, connection)).to eq("EXPLAIN QUERY PLAN #{sql}")
    end

    it "defaults to EXPLAIN for others" do
      allow(connection).to receive(:adapter_name).and_return("Oracle")
      sql = "SELECT * FROM users"
      expect(sql_subscriber.build_explain_query(sql, connection)).to eq("EXPLAIN #{sql}")
    end
  end

  describe ".start_explain_analyze_background" do
    let(:connection) { double("Connection", adapter_name: "PostgreSQL") }
    let(:connection_pool) { double("ConnectionPool") }
    let(:active_record) { double("ActiveRecord::Base") }
    let(:query_info) { { duration_ms: 1000 } }

    before do
      stub_const("ActiveRecord::Base", active_record)
      allow(active_record).to receive(:connection).and_return(connection)
      allow(active_record).to receive(:connection_pool).and_return(connection_pool)
      allow(connection_pool).to receive(:checkout).and_return(connection)
      allow(connection_pool).to receive(:checkin)
      
      # Mock the safe interpolation
      allow(sql_subscriber).to receive(:interpolate_sql_with_binds).and_return("SELECT * FROM users WHERE id = '1'")
      
      # Mock the methods used inside the thread
      allow(connection).to receive(:quote).with(1).and_return("'1'")
      allow(connection).to receive(:select_all).and_return(double("Result", rows: [["Seq Scan"]]))
    end

    it "runs EXPLAIN in a background thread and updates query_info" do
      # We need to wait for the thread to complete in the test
      allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
      
      sql_subscriber.start_explain_analyze_background("SELECT * FROM users WHERE id = $1", 123, query_info, [1])
      
      expect(query_info[:explain_plan]).to include("Seq Scan")
      expect(sql_subscriber).to have_received(:interpolate_sql_with_binds)
      expect(connection).to have_received(:select_all)
    end
  end
end

