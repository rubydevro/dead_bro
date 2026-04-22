# frozen_string_literal: true

module DeadBro
  class ElasticsearchSubscriber
    THREAD_LOCAL_KEY = :dead_bro_elasticsearch_events
    MAX_TRACKED_EVENTS = 500

    # Install gem-based notification subscriber (request.elasticsearch / request.elastic_transport).
    # The Net::HTTP path is handled by HttpInstrumentation, which calls .record directly.
    def self.subscribe!
      install_notifications_subscription!
    rescue
    end

    # Called by HttpInstrumentation when it detects a Net::HTTP request to an ES host.
    def self.record(method:, path:, status:, duration_ms:)
      events = Thread.current[THREAD_LOCAL_KEY]
      return unless events
      return unless should_continue_tracking?

      events << build_event(method, path, status, duration_ms)
    rescue
    end

    def self.start_request_tracking
      Thread.current[THREAD_LOCAL_KEY] = []
    end

    def self.stop_request_tracking
      events = Thread.current[THREAD_LOCAL_KEY]
      Thread.current[THREAD_LOCAL_KEY] = nil
      events || []
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

    def self.extract_operation(method, path)
      return "unknown" if path.nil?

      clean = path.to_s.split("?").first.to_s
      m = method.to_s.upcase

      if clean =~ /_search\z/i
        "search"
      elsif clean =~ /_msearch\z/i
        "msearch"
      elsif clean =~ /_bulk\z/i
        "bulk"
      elsif clean =~ /_doc\/[^\/]+\/_update\z/i
        "update"
      elsif clean =~ /_update\/[^\/]+\z/i
        "update"
      elsif clean =~ /_delete_by_query\z/i
        "delete_by_query"
      elsif clean =~ /_count\z/i
        "count"
      elsif clean =~ /_mapping\z/i
        m == "GET" ? "get_mapping" : "put_mapping"
      elsif clean =~ /_doc\/[^\/]+\z/i
        case m
        when "GET"        then "get"
        when "DELETE"     then "delete"
        when "POST", "PUT" then "index"
        else "doc"
        end
      elsif clean =~ /_doc\z/i
        "index"
      elsif clean =~ /\A\/_cluster\//i
        "cluster"
      elsif clean =~ /\A\/_cat\//i
        "cat"
      elsif clean =~ /\A\/[^\/]+\z/
        case m
        when "PUT"    then "create_index"
        when "DELETE" then "delete_index"
        when "HEAD"   then "index_exists"
        when "GET"    then "get_index"
        else "index_op"
        end
      else
        m.downcase
      end
    rescue
      "unknown"
    end

    def self.sanitize_path(path)
      return "" if path.nil?
      path.to_s
        .gsub(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, "/{id}")
        .gsub(/\/\d+(?=\/|\z)/, "/{id}")
    rescue
      path.to_s
    end

    class << self
      private

      def install_notifications_subscription!
        return unless defined?(::ActiveSupport::Notifications)

        %w[request.elasticsearch request.elastic_transport].each do |event_name|
          ::ActiveSupport::Notifications.subscribe(event_name) do |_name, started, finished, _id, payload|
            events = Thread.current[THREAD_LOCAL_KEY]
            next unless events
            next unless should_continue_tracking?

            duration_ms = ((finished - started) * 1000.0).round(2)
            method = payload[:method].to_s.upcase
            path = payload[:path].to_s
            events << build_event(method, path, payload[:status], duration_ms)
          rescue
          end
        end
      rescue
      end

      def build_event(method, path, status, duration_ms)
        {
          method: method.to_s.upcase,
          path: sanitize_path(path),
          operation: extract_operation(method, path),
          status: status,
          duration_ms: duration_ms
        }
      end
    end
  end
end
