# frozen_string_literal: true

require "uri"
require "net/http"

module DeadBro
  module HttpInstrumentation
    EVENT_NAME = "outgoing.http"
    THREAD_LOCAL_KEY = :dead_bro_http_events
    MAX_TRACKED_EVENTS = 1000

    def self.install!(client: Client.new)
      install_net_http!(client)
      install_typhoeus!(client) if defined?(::Typhoeus)
      install_faraday!(client) if defined?(::Faraday)
    rescue
      # Never raise from instrumentation install
    end

    def self.install_net_http!(client)
      mod = Module.new do
        define_method(:request) do |req, body = nil, &block|
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          wall_start = Time.now
          response = nil
          error = nil
          begin
            response = super(req, body, &block)
            response
          rescue Exception => e
            error = e
            raise
          ensure
            finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finish_time - start_time) * 1000.0).round(2)
            begin
              uri = begin
                URI.parse(req.uri ? req.uri.to_s : "http://#{@address}:#{@port}#{req.path}")
              rescue
                nil
              end

              host = (uri && uri.host) || @address
              port = (uri && uri.port) || @port
              is_es_host = DeadBro::HttpInstrumentation.elasticsearch_host?(host, port)
              # Skip localhost/internal only for non-ES hosts. ES on localhost (e.g. port 9200)
              # must still be tracked; only skip the deadbro backend itself.
              skip_instrumentation = !is_es_host && uri && (uri.to_s.include?("localhost") || uri.to_s.include?("aberatii.com"))

              tracking_start = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
              start_offset_ms = tracking_start ? ((wall_start - tracking_start) * 1000.0).round(2) : nil

              if is_es_host
                # Route to elasticsearch subscriber instead of http_outgoing
                if Thread.current[DeadBro::ElasticsearchSubscriber::THREAD_LOCAL_KEY]
                  path = (uri && uri.path) || req.path
                  DeadBro::ElasticsearchSubscriber.record(
                    method: req.method,
                    path: path,
                    status: response && response.code.to_i,
                    duration_ms: duration_ms,
                    start_offset_ms: start_offset_ms
                  )
                end
              elsif !skip_instrumentation
                lib = DeadBro::HttpInstrumentation.typesense_host?(host, port) ? "typesense" : "net_http"
                payload = {
                  library: lib,
                  method: req.method,
                  url: uri && uri.to_s,
                  host: host,
                  path: (uri && uri.path) || req.path,
                  status: response && response.code.to_i,
                  duration_ms: duration_ms,
                  start_offset_ms: start_offset_ms,
                  exception: error && error.class.name
                }
                if Thread.current[THREAD_LOCAL_KEY] && DeadBro::HttpInstrumentation.should_continue_tracking?
                  Thread.current[THREAD_LOCAL_KEY] << payload
                end
              end
            rescue
            end
          end
        end
      end

      ::Net::HTTP.prepend(mod) unless ::Net::HTTP.ancestors.include?(mod)
    end

    def self.install_typhoeus!(client)
      mod = Module.new do
        define_method(:run) do |*args|
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = nil
          begin
            response = super(*args)
            response
          ensure
            finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finish_time - start_time) * 1000.0).round(2)
            begin
              req_url = if respond_to?(:url)
                url
              else
                (respond_to?(:base_url) ? base_url : nil)
              end

              skip_instrumentation = req_url && (req_url.include?("localhost:3100/apm/v1/metrics") || req_url.include?("deadbro.aberatii.com/apm/v1/metrics"))

              unless skip_instrumentation
                payload = {
                  library: "typhoeus",
                  method: (respond_to?(:options) && options[:method]) ? options[:method].to_s.upcase : nil,
                  url: req_url,
                  status: response && response.code,
                  duration_ms: duration_ms
                }
                if Thread.current[THREAD_LOCAL_KEY] && DeadBro::HttpInstrumentation.should_continue_tracking?
                  Thread.current[THREAD_LOCAL_KEY] << payload
                end
              end
            rescue
            end
          end
        end
      end

      ::Typhoeus::Request.prepend(mod) unless ::Typhoeus::Request.ancestors.include?(mod)
    rescue
    end

    def self.install_faraday!(client)
      return unless defined?(::Faraday)

      unless defined?(::DeadBro::FaradayMiddleware)
        middleware_klass = Class.new(::Faraday::Middleware) do
          def call(env)
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            response = nil
            begin
              response = @app.call(env)
            ensure
              finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              duration_ms = ((finish_time - start_time) * 1000.0).round(2)
              begin
                url = env.url
                host = url.host.to_s
                port = url.port
                url_str = url.to_s

                is_es_host = DeadBro::HttpInstrumentation.elasticsearch_host?(host, port)
                skip = !is_es_host && (url_str.include?("localhost") || url_str.include?("aberatii.com"))

                if is_es_host
                  if Thread.current[DeadBro::ElasticsearchSubscriber::THREAD_LOCAL_KEY]
                    DeadBro::ElasticsearchSubscriber.record(
                      method: env.method.to_s.upcase,
                      path: url.path,
                      status: response&.status,
                      duration_ms: duration_ms
                    )
                  end
                elsif !skip
                  lib = DeadBro::HttpInstrumentation.typesense_host?(host, port) ? "typesense" : "faraday"
                  payload = {
                    library: lib,
                    method: env.method.to_s.upcase,
                    url: url_str,
                    host: host,
                    path: url.path,
                    status: response&.status,
                    duration_ms: duration_ms
                  }
                  key = DeadBro::HttpInstrumentation::THREAD_LOCAL_KEY
                  if Thread.current[key] && DeadBro::HttpInstrumentation.should_continue_tracking?
                    Thread.current[key] << payload
                  end
                end
              rescue
              end
            end
          end
        end
        ::DeadBro.const_set(:FaradayMiddleware, middleware_klass)
      end

      unless defined?(::DeadBro::FaradayInstrumentation)
        instrumentation_mod = Module.new do
          define_method(:initialize) do |url = nil, options = {}, &block|
            super(url, options, &block)
            unless builder.handlers.map(&:klass).include?(::DeadBro::FaradayMiddleware)
              builder.use(::DeadBro::FaradayMiddleware)
            end
          rescue
          end
        end
        ::DeadBro.const_set(:FaradayInstrumentation, instrumentation_mod)
      end

      ::Faraday::Connection.prepend(::DeadBro::FaradayInstrumentation) unless ::Faraday::Connection.ancestors.include?(::DeadBro::FaradayInstrumentation)
    rescue
    end

    def self.elasticsearch_host?(host, port)
      return false if host.nil?
      return true if port == 9200
      h = host.to_s
      h.end_with?(".elastic.co") || h.end_with?(".es.amazonaws.com") || h.include?("elasticsearch")
    end

    def self.typesense_host?(host, port)
      return false if host.nil?
      port == 8108 || host.to_s.end_with?(".typesense.io")
    end

    def self.should_continue_tracking?
      events = Thread.current[THREAD_LOCAL_KEY]
      return false unless events

      return false if events.length >= MAX_TRACKED_EVENTS

      start_time = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
      if start_time
        elapsed_seconds = Time.now - start_time
        return false if elapsed_seconds >= DeadBro::MAX_TRACKING_DURATION_SECONDS
      end

      true
    end
  end
end
