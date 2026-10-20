# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "timeout"

module DeadBro
  class Client
    # The job post_metric hands to the dispatcher. One small object is all the
    # host's request or job thread allocates for a metric; the payload is built
    # (when deferred), truncated, JSON-encoded and posted by the worker.
    MetricDelivery = Struct.new(:client, :event_name, :payload, :queued_at) do
      def call
        client.__send__(:deliver_metric, event_name, payload, queued_at)
      end
    end

    def initialize(configuration = DeadBro.configuration)
      @configuration = configuration
      @circuit_breaker = create_circuit_breaker
      @failures_mutex = Mutex.new
      @serialization_failures = 0
    end

    # Payloads dropped because they couldn't be built or JSON-encoded, even
    # after scrubbing.
    def serialization_failures
      @failures_mutex.synchronize { @serialization_failures }
    end

    # payload is a Hash, or an object whose #to_payload returns one (see
    # Subscriber::RequestCapture): that's called on the dispatcher worker, so
    # a payload can be assembled off the host's thread too.
    def post_metric(event_name:, payload:, force: false)
      return if @configuration.api_key.nil?
      return unless @configuration.enabled
      return if @configuration.skip_tracking?
      return if !force && !@configuration.should_sample?
      return if circuit_open?

      # sent_at keeps meaning "when the metric was reported", however long the
      # job waits in the queue. A Float, so stamping it allocates nothing.
      queued_at = Process.clock_gettime(Process::CLOCK_REALTIME)
      DeadBro::Dispatcher.instance.dispatch(MetricDelivery.new(self, event_name, payload, queued_at))

      nil
    end

    def post_heartbeat(sync: false)
      return if @configuration.api_key.nil?

      @configuration.last_heartbeat_attempt_at = Time.now.utc
      body = {event: "heartbeat", payload: {rails_env: DeadBro.env}, sent_at: Time.now.utc.iso8601, revision: @configuration.resolve_deploy_id, gem_version: DeadBro::VERSION}

      if sync
        # Called from the monitor thread on startup — run inline so settings are
        # applied before the first collection tick.
        send_request(url: metrics_endpoint_url, body: body, event_name: "heartbeat",
          apply_settings: true, settings_header: false)
      else
        dispatch_request(
          url: metrics_endpoint_url,
          body: body,
          event_name: "heartbeat",
          apply_settings: true
        )
      end

      nil
    end

    def post_monitor_stats(payload)
      return if @configuration.api_key.nil?
      return unless @configuration.enabled
      return if @configuration.skip_tracking?
      return unless @configuration.monitor_enabled
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

    # Hands the whole send — encoding included — to a dispatcher worker.
    def dispatch_request(url:, body:, event_name:, apply_settings: false)
      DeadBro::Dispatcher.instance.dispatch do
        send_request(url: url, body: body, event_name: event_name, apply_settings: apply_settings)
      end
    end

    # Runs on a dispatcher worker for metrics: what post_metric used to do on
    # the host's thread, plus building a deferred payload.
    def deliver_metric(event_name, payload, queued_at = nil)
      payload = begin
        payload.respond_to?(:to_payload) ? payload.to_payload : payload
      rescue *DeadBro::CONTAINED_ERRORS
        return record_serialization_failure
      end
      return unless payload

      payload = truncate_payload_for_request(payload)
      sent_at = (queued_at ? Time.at(queued_at) : Time.now).utc.iso8601
      body = {event: event_name, payload: payload, sent_at: sent_at, revision: @configuration.resolve_deploy_id, gem_version: DeadBro::VERSION}

      send_request(url: metrics_endpoint_url, body: body, event_name: event_name, apply_settings: true)
    end

    # Encodes body and POSTs it on the calling thread.
    def send_request(url:, body:, event_name:, apply_settings: false, settings_header: true)
      json = serialize(body)
      return unless json

      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @configuration.open_timeout
      http.read_timeout = @configuration.read_timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@configuration.api_key}"
      if settings_header && @configuration.settings_received_at
        request["X-Settings-Received-At"] = @configuration.settings_received_at.utc.iso8601
      end
      request.body = json

      perform_request(http, request, event_name: event_name, apply_settings: apply_settings)
    end

    # Must not raise: for request and job payloads this runs on the host's own
    # thread. JSON.dump raises on any String that isn't valid UTF-8; the payload
    # builders scrub the fields known to carry raw request bytes, and this
    # catches whatever else slips through (a log line, a cache key, a job
    # argument) at the cost of one retry instead of the whole payload. Returns
    # nil when the payload can't be sent.
    def serialize(body)
      JSON.dump(body)
    rescue JSON::GeneratorError, EncodingError
      begin
        JSON.dump(DeadBro::Sanitizer.deep(body))
      rescue *DeadBro::CONTAINED_ERRORS
        record_serialization_failure
      end
    rescue *DeadBro::CONTAINED_ERRORS
      # Not an encoding problem (e.g. an object whose to_json raises), so
      # scrubbing strings wouldn't help.
      record_serialization_failure
    end

    def record_serialization_failure
      @failures_mutex.synchronize { @serialization_failures += 1 }
      nil
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

        if response.is_a?(Net::HTTPSuccess)
          @configuration.skip_until = nil
        elsif response.is_a?(Net::HTTPInsufficientStorage)
          @configuration.skip_until = Time.now.utc + DeadBro::Configuration::METRICS_BACKEND_SKIP_AFTER_507_SECONDS
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

  end
end
