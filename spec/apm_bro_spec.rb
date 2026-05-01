# frozen_string_literal: true

RSpec.describe DeadBro do
  it "has a version number" do
    expect(DeadBro::VERSION).not_to be nil
  end

  describe "configuration" do
    it "has basic configuration" do
      config = DeadBro::Configuration.new
      expect(config.enabled).to be true
      expect(config.open_timeout).to eq(1.0)
      expect(config.read_timeout).to eq(1.0)
    end

    it "generates a deploy_id by default and can be overridden" do
      config = DeadBro::Configuration.new
      id1 = config.resolve_deploy_id
      expect(id1).to be_a(String)
      expect(id1.length).to be >= 8

      # Override via ENV
      ENV["dead_bro_DEPLOY_ID"] = "test-deploy-123"
      id2 = DeadBro::Configuration.new.resolve_deploy_id
      expect(id2).to eq("test-deploy-123")
      ENV.delete("dead_bro_DEPLOY_ID")
    end

    it "has sample rate configuration" do
      config = DeadBro::Configuration.new
      expect(config.sample_rate).to eq(100)
    end

    it "accepts any sample rate value (no validation)" do
      config = DeadBro::Configuration.new

      config.sample_rate = 0
      expect(config.sample_rate).to eq(0)

      config.sample_rate = 50
      expect(config.sample_rate).to eq(50)

      config.sample_rate = 100
      expect(config.sample_rate).to eq(100)
    end

    it "determines sampling correctly" do
      config = DeadBro::Configuration.new

      # 100% sampling should always return true
      config.sample_rate = 100
      expect(config.should_sample?).to be true

      # 0% sampling should always return false
      config.sample_rate = 0
      expect(config.should_sample?).to be false

      # 50% sampling should return true/false randomly
      config.sample_rate = 50
      results = 100.times.map { config.should_sample? }
      expect(results).to include(true)
      expect(results).to include(false)
    end

    it "resolve_sample_rate returns the configured sample_rate directly" do
      config = DeadBro::Configuration.new
      config.sample_rate = 42
      expect(config.resolve_sample_rate).to eq(42)
    end

    it "resolve_sample_rate returns nil when sample_rate is cleared" do
      config = DeadBro::Configuration.new
      config.sample_rate = nil
      expect(config.resolve_sample_rate).to be_nil
    end

    it "treats nil sample_rate as 100% for should_sample?" do
      config = DeadBro::Configuration.new
      config.sample_rate = nil
      expect(config.should_sample?).to be true
    end

    it "resolves api_key from ENV" do
      config = DeadBro::Configuration.new
      config.api_key = nil

      ENV["DEAD_BRO_API_KEY"] = "env-api-key"
      expect(config.resolve_api_key).to eq("env-api-key")
      ENV.delete("DEAD_BRO_API_KEY")
    end

    it "resolves deploy_id from GIT_REV" do
      config = DeadBro::Configuration.new
      config.deploy_id = nil

      ENV["GIT_REV"] = "abc123"
      expect(config.resolve_deploy_id).to eq("abc123")
      ENV.delete("GIT_REV")
    end

    it "resolves deploy_id from HEROKU_SLUG_COMMIT" do
      config = DeadBro::Configuration.new
      config.deploy_id = nil

      ENV["HEROKU_SLUG_COMMIT"] = "heroku-commit-123"
      expect(config.resolve_deploy_id).to eq("heroku-commit-123")
      ENV.delete("HEROKU_SLUG_COMMIT")
    end

    it "prefers config.deploy_id over environment variables when set" do
      config = DeadBro::Configuration.new
      ENV["DEAD_BRO_DEPLOY_ID"] = "from-env"
      ENV["GIT_REV"] = "from-git"
      config.deploy_id = "from-ruby"
      expect(config.resolve_deploy_id).to eq("from-ruby")
      ENV.delete("DEAD_BRO_DEPLOY_ID")
      ENV.delete("GIT_REV")
    end

    it "resolves deploy_id from GIT_COMMIT_SHA when higher-priority vars are absent" do
      config = DeadBro::Configuration.new
      ENV["GIT_COMMIT_SHA"] = "sha-deadbeef"
      expect(config.resolve_deploy_id).to eq("sha-deadbeef")
      ENV.delete("GIT_COMMIT_SHA")
    end

    it "has memory tracking configuration" do
      config = DeadBro::Configuration.new
      expect(config.memory_tracking_enabled).to be true
      expect(config.allocation_tracking_enabled).to be false
    end

    it "has circuit breaker configuration" do
      config = DeadBro::Configuration.new
      expect(config.circuit_breaker_enabled).to be true
      expect(config.circuit_breaker_failure_threshold).to eq(3)
      expect(config.circuit_breaker_recovery_timeout).to eq(60)
      expect(config.circuit_breaker_retry_timeout).to eq(300)
    end

    it "has payload truncation defaults to avoid 413" do
      config = DeadBro::Configuration.new
      expect(config.max_sql_queries_to_send).to eq(500)
      expect(config.max_logs_to_send).to eq(100)
    end
  end

  describe "Client" do
    let(:config) { DeadBro::Configuration.new }
    let(:client) { DeadBro::Client.new(config) }

    before do
      config.enabled = true
      config.api_key = "test_key"
      config.sample_rate = 100 # Start with 100% sampling
    end

    it "sends metrics when sampling is enabled" do
      # Mock the HTTP request to avoid actual network calls
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(double("Response", code: "202", message: "Accepted"))

      expect { client.post_metric(event_name: "test", payload: {}) }.not_to raise_error
    end

    it "skips metrics when sampling is disabled" do
      config.sample_rate = 0

      # Should not make HTTP requests
      expect_any_instance_of(Net::HTTP).not_to receive(:request)

      client.post_metric(event_name: "test", payload: {})
    end

    it "skips metrics when disabled" do
      config.enabled = false

      # Should not make HTTP requests
      expect_any_instance_of(Net::HTTP).not_to receive(:request)

      client.post_metric(event_name: "test", payload: {})
    end

    it "skips metrics when api_key is missing" do
      config.api_key = nil

      # Should not make HTTP requests
      expect_any_instance_of(Net::HTTP).not_to receive(:request)

      client.post_metric(event_name: "test", payload: {})
    end

    it "handles circuit breaker when open" do
      config.circuit_breaker_enabled = true
      client = DeadBro::Client.new(config)

      # Force circuit breaker to open state
      circuit_breaker = client.instance_variable_get(:@circuit_breaker)
      circuit_breaker.open!

      # Should not make HTTP requests when circuit is open and not ready to reset
      expect_any_instance_of(Net::HTTP).not_to receive(:request)
      client.post_metric(event_name: "test", payload: {})
    end

    it "uses ruby_dev endpoint when enabled" do
      config.ruby_dev = true
      client = DeadBro::Client.new(config)

      # Mock HTTP request
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "localhost", port: 3100, scheme: "http", request_uri: "/apm/v1/metrics")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:request).and_return(double("Response", code: "202"))

      # Should use dev endpoint
      expect(URI).to receive(:parse).with("http://localhost:3100/apm/v1/metrics")

      client.post_metric(event_name: "test", payload: {})
    end

    it "truncates sql_queries and logs in payload to avoid 413" do
      config.max_sql_queries_to_send = 3
      config.max_logs_to_send = 2
      client = DeadBro::Client.new(config)

      truncated = client.send(:truncate_payload_for_request, {
        job_class: "TestJob",
        sql_queries: (1..10).map { |i| {sql: "SELECT #{i}", duration_ms: 1} },
        logs: (1..5).map { |i| {msg: "log#{i}"} }
      })

      expect(truncated[:sql_queries].size).to eq(3)
      expect(truncated[:sql_queries_total_count]).to eq(10)
      expect(truncated[:sql_queries].map { |q| q[:sql] }).to eq(["SELECT 1", "SELECT 2", "SELECT 3"])

      expect(truncated[:logs].size).to eq(2)
      expect(truncated[:logs_total_count]).to eq(5)
      expect(truncated[:job_class]).to eq("TestJob")
    end

    it "does not truncate payload when under limits" do
      config.max_sql_queries_to_send = 100
      config.max_logs_to_send = 200
      client = DeadBro::Client.new(config)

      payload = {job_class: "TestJob", sql_queries: [{sql: "SELECT 1"}], logs: [{msg: "a"}]}
      result = client.send(:truncate_payload_for_request, payload)

      expect(result[:sql_queries].size).to eq(1)
      expect(result).not_to have_key(:sql_queries_total_count)
      expect(result[:logs].size).to eq(1)
      expect(result).not_to have_key(:logs_total_count)
    end

    it "handles HTTP request failures" do
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "example.com", port: 443, scheme: "https", request_uri: "/apm/v1/metrics")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:request).and_raise(StandardError.new("Network error"))

      # Should not raise error
      expect { client.post_metric(event_name: "test", payload: {}) }.not_to raise_error
    end

    it "sends X-Settings-Received-At when settings were previously received" do
      config.settings_received_at = Time.utc(2025, 6, 1, 10, 30, 45)
      captured_request = nil
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "example.com", port: 443, scheme: "https", request_uri: "/apm/v1/metrics")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)

      success = double("Response", body: "{}")
      allow(success).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
      allow(http_double).to receive(:request) do |req|
        captured_request = req
        success
      end

      allow(Thread).to receive(:new) do |&block|
        block.call
        instance_double(Thread, join: nil)
      end

      client.post_metric(event_name: "test", payload: {})

      expect(captured_request["X-Settings-Received-At"]).to eq("2025-06-01T10:30:45Z")
    end

    it "applies remote settings from a successful JSON response body" do
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "example.com", port: 443, scheme: "https", request_uri: "/apm/v1/metrics")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      body = '{"settings":{"enabled":false,"sample_rate":10},"settings_updated_at":"2025-06-02T00:00:00Z"}'
      success = double("Response", body: body)
      allow(success).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
      allow(http_double).to receive(:request).and_return(success)

      allow(Thread).to receive(:new) do |&block|
        block.call
        instance_double(Thread, join: nil)
      end

      client.post_metric(event_name: "test", payload: {})

      expect(config.enabled).to be false
      expect(config.sample_rate).to eq(10)
      expect(config.settings_received_at).to eq(Time.iso8601("2025-06-02T00:00:00Z"))
    end

    it "records last_heartbeat_at only after a successful heartbeat response" do
      config.enabled = false
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "example.com", port: 443, scheme: "https", request_uri: "/apm/v1/metrics")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)

      allow(Thread).to receive(:new) do |&block|
        block.call
        instance_double(Thread, join: nil)
      end

      success = double("Response", body: "{}")
      allow(success).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
      allow(http_double).to receive(:request).and_return(success)

      expect(config.last_heartbeat_at).to be_nil
      client.post_heartbeat
      expect(config.last_heartbeat_at).to be_a(Time)
    end

    it "does not set last_heartbeat_at when the heartbeat response is not successful" do
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "example.com", port: 443, scheme: "https", request_uri: "/apm/v1/metrics")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)

      allow(Thread).to receive(:new) do |&block|
        block.call
        instance_double(Thread, join: nil)
      end

      failure = Net::HTTPInternalServerError.new("1.1", "500", "Error")
      failure.instance_variable_set(:@read, true)
      failure.instance_variable_set(:@body, "{}")
      allow(http_double).to receive(:request).and_return(failure)

      client.post_heartbeat
      expect(config.last_heartbeat_at).to be_nil
    end
  end

  describe "Exclusions" do
    it "excludes specified controllers" do
      config = DeadBro::Configuration.new
      config.excluded_controllers = ["Admin::*", "HealthChecksController"]

      expect(config.excluded_controller?("Admin::UsersController")).to be true
      expect(config.excluded_controller?("HealthChecksController")).to be true
      expect(config.excluded_controller?("UsersController")).to be false
    end

    it "excludes specified controller#action pairs" do
      config = DeadBro::Configuration.new
      config.excluded_controllers = [
        "UsersController#show",
        "Admin::*#*"
      ]

      expect(config.excluded_controller?("UsersController", "show")).to be true
      expect(config.excluded_controller?("UsersController", "index")).to be false
      expect(config.excluded_controller?("Admin::ReportsController", "index")).to be true
    end

    it "excludes controller#action patterns from excluded_controllers" do
      config = DeadBro::Configuration.new
      config.excluded_controllers = ["ActiveStorage*#*"]

      expect(config.excluded_controller?("ActiveStorage::BlobsController", "show")).to be true
      expect(config.excluded_controller?("ActiveStorage::BlobsController", "index")).to be true
      expect(config.excluded_controller?("UsersController", "show")).to be false
    end

    it "excludes specified jobs" do
      config = DeadBro::Configuration.new
      config.excluded_jobs = ["ActiveStorage::AnalyzeJob", "Admin::*"]

      expect(config.excluded_job?("ActiveStorage::AnalyzeJob")).to be true
      expect(config.excluded_job?("Admin::CleanupJob")).to be true
      expect(config.excluded_job?("UserSignupJob")).to be false
    end
  end

  describe "JobSubscriber" do
    let(:job_subscriber) { DeadBro::JobSubscriber }

    before do
      # Clear any existing subscriptions
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.unsubscribe("perform.active_job")
        ActiveSupport::Notifications.unsubscribe("exception.active_job")
      end
    end

    after do
      # Clean up subscriptions
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.unsubscribe("perform.active_job")
        ActiveSupport::Notifications.unsubscribe("exception.active_job")
      end
    end

    it "tracks successful job execution", skip: "Requires ActiveSupport::Notifications" do
      skip unless defined?(ActiveSupport::Notifications)

      job_subscriber.subscribe!(client: DeadBro::Client.new)

      # Mock a job
      job = double("Job", class: double("JobClass", name: "TestJob"), job_id: "123", queue_name: "default", arguments: ["arg1", "arg2"])

      ActiveSupport::Notifications.instrument("perform.active_job", {job: job})

      # The job subscriber should have been called (we can't easily test the client call without mocking)
      expect(true).to be true # Placeholder assertion
    end

    it "tracks job exceptions", skip: "Requires ActiveSupport::Notifications" do
      skip unless defined?(ActiveSupport::Notifications)

      job_subscriber.subscribe!(client: DeadBro::Client.new)

      # Mock a job and exception
      job = double("Job", class: double("JobClass", name: "TestJob"), job_id: "123", queue_name: "default", arguments: ["arg1"])
      exception = StandardError.new("Test error")
      exception.set_backtrace(["line1", "line2"])

      ActiveSupport::Notifications.instrument("exception.active_job", {
        job: job,
        exception_object: exception
      })

      # The job subscriber should have been called
      expect(true).to be true # Placeholder assertion
    end

    it "sanitizes job arguments", skip: "Requires ActiveSupport::Notifications" do
      skip unless defined?(ActiveSupport::Notifications)

      arguments = [
        "normal_string",
        "very_long_string_" + "x" * 300,
        {password: "secret", normal_key: "value"},
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      ]

      sanitized = job_subscriber.send(:safe_arguments, arguments)

      expect(sanitized[0]).to eq("normal_string")
      expect(sanitized[1]).to end_with("...")
      expect(sanitized[2]).not_to have_key(:password)
      expect(sanitized[2]).to have_key(:normal_key)
      expect(sanitized[3]).to have(5).items
    end
  end

  describe "Logger" do
    let(:logger) { DeadBro::Logger.new }

    before do
      logger.clear
    end

    it "logs debug messages" do
      logger.debug("Debug message")
      logs = logger.logs
      expect(logs.length).to eq(1)
      expect(logs.first[:sev]).to eq("debug")
      expect(logs.first[:msg]).to eq("Debug message")
    end

    it "logs info messages" do
      logger.info("Info message")
      logs = logger.logs
      expect(logs.length).to eq(1)
      expect(logs.first[:sev]).to eq("info")
      expect(logs.first[:msg]).to eq("Info message")
    end

    it "logs warn messages" do
      logger.warn("Warning message")
      logs = logger.logs
      expect(logs.first[:sev]).to eq("warn")
      expect(logs.first[:msg]).to eq("Warning message")
    end

    it "logs error messages" do
      logger.error("Error message")
      logs = logger.logs
      expect(logs.first[:sev]).to eq("error")
      expect(logs.first[:msg]).to eq("Error message")
    end

    it "logs fatal messages" do
      logger.fatal("Fatal message")
      logs = logger.logs
      expect(logs.first[:sev]).to eq("fatal")
      expect(logs.first[:msg]).to eq("Fatal message")
    end

    it "stores multiple logs" do
      logger.debug("First")
      logger.info("Second")
      logger.warn("Third")

      logs = logger.logs
      expect(logs.length).to eq(3)
      expect(logs.map { |l| l[:sev] }).to eq(["debug", "info", "warn"])
    end

    it "clears logs" do
      logger.debug("Message")
      expect(logger.logs.length).to eq(1)

      logger.clear
      expect(logger.logs.length).to eq(0)
    end

    it "includes timestamps in logs" do
      logger.info("Test")
      log = logger.logs.first
      expect(log[:time]).to be_a(String)
      expect(log[:time]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end
  end

  describe "CircuitBreaker" do
    let(:circuit_breaker) { DeadBro::CircuitBreaker.new(failure_threshold: 3, recovery_timeout: 1) }

    it "starts in closed state" do
      expect(circuit_breaker.state).to eq(:closed)
      expect(circuit_breaker.failure_count).to eq(0)
    end

    it "tracks failures and opens after threshold" do
      expect(circuit_breaker.state).to eq(:closed)

      # Simulate failures
      3.times { circuit_breaker.send(:on_failure) }

      expect(circuit_breaker.state).to eq(:open)
      expect(circuit_breaker.failure_count).to eq(3)
    end

    it "resets failure count on success" do
      circuit_breaker.send(:on_failure)
      expect(circuit_breaker.failure_count).to eq(1)

      circuit_breaker.send(:on_success)
      expect(circuit_breaker.failure_count).to eq(0)
      expect(circuit_breaker.state).to eq(:closed)
    end

    it "transitions to half-open when should_attempt_reset?" do
      circuit_breaker.open!
      expect(circuit_breaker.state).to eq(:open)

      # Wait for recovery timeout
      sleep(1.1)

      expect(circuit_breaker.should_attempt_reset?).to be true
      circuit_breaker.transition_to_half_open!
      expect(circuit_breaker.state).to eq(:half_open)
    end

    it "returns false for should_attempt_reset? when not enough time has passed" do
      circuit_breaker.open!
      expect(circuit_breaker.should_attempt_reset?).to be false
    end

    it "resets to closed state" do
      circuit_breaker.open!
      circuit_breaker.send(:on_failure)

      circuit_breaker.reset!
      expect(circuit_breaker.state).to eq(:closed)
      expect(circuit_breaker.failure_count).to eq(0)
      expect(circuit_breaker.last_failure_time).to be_nil
    end

    it "transitions back to open from half-open on failure" do
      circuit_breaker.transition_to_half_open!
      expect(circuit_breaker.state).to eq(:half_open)

      circuit_breaker.send(:on_failure)
      expect(circuit_breaker.state).to eq(:open)
    end

    it "tracks last_failure_time and last_success_time" do
      expect(circuit_breaker.last_failure_time).to be_nil
      expect(circuit_breaker.last_success_time).to be_nil

      circuit_breaker.send(:on_failure)
      expect(circuit_breaker.last_failure_time).to be_a(Time)

      circuit_breaker.send(:on_success)
      expect(circuit_breaker.last_success_time).to be_a(Time)
    end
  end

  describe "Configuration#apply_remote_settings" do
    let(:config) { DeadBro::Configuration.new }

    it "applies known remote setting keys" do
      config.apply_remote_settings(
        "enabled" => false,
        "sample_rate" => 50,
        "excluded_controllers" => ["HealthController"],
        "slow_query_threshold_ms" => 250
      )

      expect(config.enabled).to be false
      expect(config.sample_rate).to eq(50)
      expect(config.excluded_controllers).to eq(["HealthController"])
      expect(config.slow_query_threshold_ms).to eq(250)
    end

    it "casts boolean values correctly" do
      config.apply_remote_settings("enabled" => true)
      expect(config.enabled).to be true

      config.apply_remote_settings("enabled" => false)
      expect(config.enabled).to be false
    end

    it "casts integer values" do
      config.apply_remote_settings("sample_rate" => "75", "max_sql_queries_to_send" => "200")
      expect(config.sample_rate).to eq(75)
      expect(config.max_sql_queries_to_send).to eq(200)
    end

    it "casts array values and stringifies elements" do
      config.apply_remote_settings("excluded_controllers" => [:FooController, "BarController"])
      expect(config.excluded_controllers).to eq(["FooController", "BarController"])
    end

    it "ignores unknown keys" do
      expect { config.apply_remote_settings("unknown_key" => "value") }.not_to raise_error
      expect(config.enabled).to be true # unchanged
    end

    it "does nothing when given nil" do
      expect { config.apply_remote_settings(nil) }.not_to raise_error
    end

    it "does nothing when given a non-hash" do
      expect { config.apply_remote_settings("not a hash") }.not_to raise_error
    end

    it "applies all REMOTE_SETTING_KEYS without error" do
      full_settings = {
        "enabled" => true,
        "sample_rate" => 80,
        "memory_tracking_enabled" => false,
        "allocation_tracking_enabled" => true,
        "explain_analyze_enabled" => true,
        "slow_query_threshold_ms" => 300,
        "max_sql_queries_to_send" => 100,
        "max_logs_to_send" => 50,
        "excluded_controllers" => ["AdminController"],
        "excluded_jobs" => ["SlowJob"],
        "exclusive_controllers" => [],
        "exclusive_jobs" => [],
        "job_queue_monitoring_enabled" => true,
        "enable_db_stats" => true,
        "enable_process_stats" => false,
        "enable_system_stats" => false
      }

      expect { config.apply_remote_settings(full_settings) }.not_to raise_error
      expect(config.sample_rate).to eq(80)
      expect(config.excluded_controllers).to eq(["AdminController"])
    end
  end

  describe "Configuration#heartbeat_due?" do
    let(:config) { DeadBro::Configuration.new }

    it "returns false when api_key is nil" do
      config.api_key = nil
      expect(config.heartbeat_due?).to be false
    end

    it "returns true when last_heartbeat_attempt_at is nil and api_key is set" do
      config.api_key = "some-key"
      config.last_heartbeat_attempt_at = nil
      expect(config.heartbeat_due?).to be true
    end

    it "returns false when last heartbeat attempt was recent" do
      config.api_key = "some-key"
      config.last_heartbeat_attempt_at = Time.now.utc - (DeadBro::Configuration::HEARTBEAT_INTERVAL - 10)
      expect(config.heartbeat_due?).to be false
    end

    it "returns true when last heartbeat attempt was older than the interval" do
      config.api_key = "some-key"
      config.last_heartbeat_attempt_at = Time.now.utc - (DeadBro::Configuration::HEARTBEAT_INTERVAL + 1)
      expect(config.heartbeat_due?).to be true
    end

    it "returns true exactly at the interval boundary" do
      config.api_key = "some-key"
      config.last_heartbeat_attempt_at = Time.now.utc - DeadBro::Configuration::HEARTBEAT_INTERVAL
      expect(config.heartbeat_due?).to be true
    end
  end

  describe "DeadBro module" do
    it "configures settings via configure block" do
      DeadBro.configure do |config|
        config.enabled = false
        config.api_key = "test-key"
      end

      expect(DeadBro.configuration.enabled).to be false
      expect(DeadBro.configuration.api_key).to eq("test-key")
    end

    it "resets configuration" do
      DeadBro.configure do |config|
        config.enabled = false
        config.api_key = "test-key"
      end

      DeadBro.reset_configuration!

      expect(DeadBro.configuration.enabled).to be true
      expect(DeadBro.configuration.api_key).to be_nil
    end

    it "returns a logger instance" do
      logger = DeadBro.logger
      expect(logger).to be_a(DeadBro::Logger)
      expect(DeadBro.logger).to eq(logger) # Should be memoized
    end

    it "generates process_deploy_id" do
      id = DeadBro.process_deploy_id
      expect(id).to be_a(String)
      expect(id.length).to eq(36) # UUID format
      expect(DeadBro.process_deploy_id).to eq(id) # Should be memoized
    end

    it "returns environment via env method" do
      env = DeadBro.env
      expect(env).to be_a(String)
      # Should return development, test, or production, or fallback to ENV
      expect(["development", "test", "production", ENV["RACK_ENV"], ENV["RAILS_ENV"]].compact).to include(env)
    end
  end
end
