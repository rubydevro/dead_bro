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

    def post_metric(event_name:, payload:)
      return if @configuration.api_key.nil?
      return unless @configuration.enabled

      # Check sampling rate - skip if not selected for sampling
      return unless @configuration.should_sample?
      
      # Check circuit breaker before making request
      if @circuit_breaker && @configuration.circuit_breaker_enabled
        if @circuit_breaker.state == :open
          # Check if we should attempt a reset to half-open state
          if @circuit_breaker.should_attempt_reset?
            @circuit_breaker.transition_to_half_open!
          else
            return
          end
        end
      end

      # Make the HTTP request (async)
      make_http_request(event_name, payload, @configuration.api_key)

      nil
    end

    private

    def create_circuit_breaker
      return nil unless @configuration.circuit_breaker_enabled

      CircuitBreaker.new(
        failure_threshold: @configuration.circuit_breaker_failure_threshold,
        recovery_timeout: @configuration.circuit_breaker_recovery_timeout,
        retry_timeout: @configuration.circuit_breaker_retry_timeout
      )
    end

    def make_http_request(event_name, payload, api_key)
      use_staging = ENV["USE_STAGING_ENDPOINT"] && !ENV["USE_STAGING_ENDPOINT"].empty?
      production_url = use_staging ? "https://deadbro.aberatii.com/apm/v1/metrics" : "https://www.deadbro.com/apm/v1/metrics"
      endpoint_url = @configuration.ruby_dev ? "http://localhost:3100/apm/v1/metrics" : production_url
      uri = URI.parse(endpoint_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @configuration.open_timeout
      http.read_timeout = @configuration.read_timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{api_key}"
      body = {event: event_name, payload: payload, sent_at: Time.now.utc.iso8601, revision: @configuration.resolve_deploy_id}
      request.body = JSON.dump(body)

      # Fire-and-forget using a short-lived thread to avoid blocking the request cycle.
      Thread.new do
        response = http.request(request)

        if response
          # Update circuit breaker based on response
          if @circuit_breaker && @configuration.circuit_breaker_enabled
            if response.is_a?(Net::HTTPSuccess)
              @circuit_breaker.send(:on_success)
            else
              @circuit_breaker.send(:on_failure)
            end
          end
        elsif @circuit_breaker && @configuration.circuit_breaker_enabled
          # Treat nil response as failure for circuit breaker
          @circuit_breaker.send(:on_failure)
        end

        response
      rescue Timeout::Error
        # Update circuit breaker on timeout
        if @circuit_breaker && @configuration.circuit_breaker_enabled
          @circuit_breaker.send(:on_failure)
        end
      rescue
        # Update circuit breaker on exception
        if @circuit_breaker && @configuration.circuit_breaker_enabled
          @circuit_breaker.send(:on_failure)
        end
      end

      nil
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
