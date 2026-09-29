# frozen_string_literal: true

require "rack"

module DeadBro
  class ErrorMiddleware
    EVENT_NAME = "exception.uncaught"

    def initialize(app, client = nil)
      @app = app
      @client = client || DeadBro.client
    end

    def call(env)
      @app.call(env)
    rescue Exception => exception # rubocop:disable Lint/RescueException
      begin
        payload = build_payload(exception, env)
        # Use the error class name as the event name
        event_name = exception.class.name.to_s
        event_name = EVENT_NAME if event_name.empty?
        @client.post_metric(event_name: event_name, payload: payload, force: true)
      rescue *DeadBro::CONTAINED_ERRORS
        # Never let APM reporting interfere with the host app — in particular,
        # never replace the host's exception with one of ours.
      end
      raise
    end

    private

    def build_payload(exception, env)
      req = rack_request(env)

      payload = {
        exception_class: exception.class.name,
        message: truncate(exception.message.to_s, 1000),
        backtrace: safe_backtrace(exception),
        fingerprint: DeadBro::Subscriber.compute_error_fingerprint(exception),
        cause_chain: DeadBro::Subscriber.build_cause_chain(exception),
        occurred_at: Time.now.utc.to_i,
        rack:
          {
            method: req&.request_method,
            path: req&.path,
            fullpath: req&.fullpath,
            ip: req&.ip,
            user_agent: truncate(req&.user_agent.to_s, 200),
            params: safe_params(req),
            request_id: env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"],
            referer: truncate(env["HTTP_REFERER"].to_s, 500),
            host: env["HTTP_HOST"]
          },
        rails_env: DeadBro.env,
        app: safe_app_name,
        pid: Process.pid,
        process_kind: DeadBro.process_kind,
        logs: DeadBro.logger.logs
      }
      # Every field above can carry raw client bytes (headers are binary strings),
      # so scrub the whole payload rather than field by field. This path only
      # runs for uncaught exceptions, so the extra walk is cheap.
      DeadBro::Sanitizer.deep(payload)
    end

    def rack_request(env)
      ::Rack::Request.new(env)
    rescue
      nil
    end

    def safe_backtrace(exception)
      Array(exception.backtrace).first(50)
    rescue
      []
    end

    def safe_params(req)
      return {} unless req

      params = req.params || {}
      # Redact at every nesting level (e.g. user[password]) before serializing.
      JSON.parse(JSON.dump(DeadBro::Sanitizer.deep(redact_sensitive(params))))
    rescue
      {}
    end

    def redact_sensitive(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), memo|
          # Scrubbed first: the sensitive-key regex raises on a key that isn't valid UTF-8.
          k = DeadBro::Sanitizer.string(k) if k.is_a?(String)
          memo[k] = DeadBro::Subscriber.sensitive_key?(k) ? "[FILTERED]" : redact_sensitive(v)
        end
      when Array
        value.map { |v| redact_sensitive(v) }
      else
        value
      end
    end

    def truncate(str, max)
      return str if str.nil? || str.length <= max
      str[0..(max - 1)]
    end

    def safe_app_name
      if defined?(Rails) && Rails.respond_to?(:application)
        begin
          Rails.application.class.module_parent_name
        rescue
          ""
        end
      else
        ""
      end
    end
  end
end
