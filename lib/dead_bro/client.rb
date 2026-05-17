# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "timeout"

module DeadBro
  class Client
    def initialize(configuration = DeadBro.configuration)
      @configuration = configuration
      @circuit_breaker = create_circuit_breaker
    end

    def post_metric(event_name:, payload:, force: false)
      return if @configuration.api_key.nil?
      return unless @configuration.enabled
      return if !force && !@configuration.should_sample?
      return if circuit_open?

      payload = truncate_payload_for_request(payload)
      body = {event: event_name, payload: payload, sent_at: Time.now.utc.iso8601, revision: @configuration.resolve_deploy_id, gem_version: DeadBro::VERSION}

      dispatch_request(
        url: metrics_endpoint_url,
        body: body,
        event_name: event_name,
        apply_settings: true
      )

      nil
    end

    def post_heartbeat
      return if @configuration.api_key.nil?

      @configuration.last_heartbeat_attempt_at = Time.now.utc
      body = {event: "heartbeat", payload: {}, sent_at: Time.now.utc.iso8601, revision: @configuration.resolve_deploy_id, gem_version: DeadBro::VERSION}

      dispatch_request(
        url: metrics_endpoint_url,
        body: body,
        event_name: "heartbeat",
        apply_settings: true
      )

      nil
    end

    def post_monitor_stats(payload)
      return if @configuration.api_key.nil?
      return unless @configuration.enabled
      return unless @configuration.job_queue_monitoring_enabled
      return if circuit_open?

      body = {payload: payload, sent_at: Time.now.utc.iso8601, revision: @configuration.resolve_deploy_id, gem_version: DeadBro::VERSION}

      dispatch_request(
        url: monitor_endpoint_url,
        body: body,
        event_name: nil,
        apply_settings: false
      )

      nil
    end

    private

    # Returns true (and short-circuits) when the circuit is open and not ready
    # to probe. Transitions to HALF_OPEN when the recovery timeout has elapsed.
    def circuit_open?
      return false unless @circuit_breaker && @configuration.circuit_breaker_enabled
      return false unless @circuit_breaker.state == :open

      if @circuit_breaker.should_attempt_reset?
        @circuit_breaker.transition_to_half_open!
        false
      else
        true
      end
    end

    def metrics_endpoint_url
      if @configuration.ruby_dev
        "http://localhost:3100/apm/v1/metrics"
      elsif ENV["USE_STAGING_ENDPOINT"] && !ENV["USE_STAGING_ENDPOINT"].empty?
        "https://deadbro.aberatii.com/apm/v1/metrics"
      else
        "https://www.deadbro.com/apm/v1/metrics"
      end
    end

    def monitor_endpoint_url
      if @configuration.ruby_dev
        "http://localhost:3100/apm/v1/monitor"
      elsif ENV["USE_STAGING_ENDPOINT"] && !ENV["USE_STAGING_ENDPOINT"].empty?
        "https://deadbro.aberatii.com/apm/v1/monitor"
      else
        "https://www.deadbro.com/apm/v1/monitor"
      end
    end

    def dispatch_request(url:, body:, event_name:, apply_settings: false)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @configuration.open_timeout
      http.read_timeout = @configuration.read_timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@configuration.api_key}"
      if @configuration.settings_received_at
        request["X-Settings-Received-At"] = @configuration.settings_received_at.utc.iso8601
      end
      request.body = JSON.dump(body)

      DeadBro::Dispatcher.instance.dispatch do
        perform_request(http, request, event_name: event_name, apply_settings: apply_settings)
      end
    end

    def perform_request(http, request, event_name:, apply_settings: false)
      response = http.request(request)

      if response
        if @circuit_breaker && @configuration.circuit_breaker_enabled
          if response.is_a?(Net::HTTPSuccess)
            @circuit_breaker.record_success
          else
            @circuit_breaker.record_failure
          end
        end

        if apply_settings
          apply_settings_from_response(response)

          if response.is_a?(Net::HTTPSuccess) && event_name == "heartbeat"
            @configuration.last_heartbeat_at = Time.now.utc
          end
        end
      elsif @circuit_breaker && @configuration.circuit_breaker_enabled
        @circuit_breaker.record_failure
      end

      response
    rescue Timeout::Error
      @circuit_breaker&.record_failure if @configuration.circuit_breaker_enabled
      nil
    rescue
      @circuit_breaker&.record_failure if @configuration.circuit_breaker_enabled
      nil
    end

    def apply_settings_from_response(response)
      return unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      return unless body.is_a?(Hash) && body["settings"].is_a?(Hash)

      @configuration.apply_remote_settings(body["settings"])

      updated_at_str = body["settings_updated_at"]
      @configuration.settings_received_at = updated_at_str ? Time.iso8601(updated_at_str) : Time.now.utc
    rescue JSON::ParserError, ArgumentError
      # Malformed response — ignore, settings stay as-is
    end

    def truncate_payload_for_request(payload)
      return payload unless payload.is_a?(Hash)

      max_sql = @configuration.max_sql_queries_to_send
      max_logs = @configuration.max_logs_to_send

      out = payload.dup

      if out.key?(:sql_queries) && out[:sql_queries].is_a?(Array) && out[:sql_queries].size > max_sql
        out[:sql_queries_total_count] = out[:sql_queries].size
        out[:sql_queries] = out[:sql_queries].first(max_sql)
      end

      if out.key?(:logs) && out[:logs].is_a?(Array) && out[:logs].size > max_logs
        out[:logs_total_count] = out[:logs].size
        out[:logs] = out[:logs].first(max_logs)
      end

      out
    end

    def create_circuit_breaker
      return nil unless @configuration.circuit_breaker_enabled

      CircuitBreaker.new(
        failure_threshold: @configuration.circuit_breaker_failure_threshold,
        recovery_timeout: @configuration.circuit_breaker_recovery_timeout,
        retry_timeout: @configuration.circuit_breaker_retry_timeout
      )
    end

    def log_debug(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.debug(message)
      else
        $stdout.puts(message)
      end
    end
  end
end
