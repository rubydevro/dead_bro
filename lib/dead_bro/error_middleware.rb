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
        @client.post_metric(event_name: event_name, payload: payload)
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
        rails_env: safe_rails_env,
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

    def safe_rails_env
      if defined?(Rails) && Rails.respond_to?(:env)
        Rails.env
      else
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end
    rescue
      "development"
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
