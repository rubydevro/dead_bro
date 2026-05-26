# frozen_string_literal: true

require "digest"
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
      rescue
        # Never let APM reporting interfere with the host app
      end
      raise
    end

    private

    def build_payload(exception, env)
      req = rack_request(env)

      {
        exception_class: exception.class.name,
        message: truncate(exception.message.to_s, 1000),
        backtrace: safe_backtrace(exception),
        fingerprint: compute_fingerprint(exception),
        cause_chain: build_cause_chain(exception),
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
        logs: DeadBro.logger.logs
      }
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

    def normalize_message(msg)
      msg.to_s
        .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "UUID")
        .gsub(/\b\d+\b/, "N")
        .gsub(/"[^"]*"/, '"?"')
        .gsub(/'[^']*'/, "'?'")
        .strip
    end

    def compute_fingerprint(exception)
      top_frame = Array(exception.backtrace).first.to_s.gsub(/:\d+:in /, ":N:in ")
      input = "#{exception.class.name}|#{normalize_message(exception.message)}|#{top_frame}"
      Digest::SHA256.hexdigest(input)[0, 16]
    rescue
      nil
    end

    def build_cause_chain(exception)
      return [] unless exception
      chain = []
      cause = exception.cause
      depth = 0
      while cause && depth < 5
        chain << {
          exception_class: cause.class.name,
          message: truncate(cause.message.to_s, 500),
          backtrace_top: Array(cause.backtrace).first(3)
        }
        cause = cause.cause
        depth += 1
      end
      chain
    rescue
      []
    end

    def safe_params(req)
      return {} unless req

      params = req.params || {}
      sensitive_keys = %w[password password_confirmation token secret key authorization api_key]
      filtered = params.dup
      sensitive_keys.each do |k|
        filtered.delete(k)
        filtered.delete(k.to_sym)
      end
      JSON.parse(JSON.dump(filtered)) # ensure JSON-safe
    rescue
      {}
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
