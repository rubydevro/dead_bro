# frozen_string_literal: true

require "active_support/notifications"

module DeadBro
  class CacheSubscriber
    THREAD_LOCAL_KEY = :dead_bro_cache_events
    MAX_TRACKED_EVENTS = 1000

    EVENTS = [
      "cache_read.active_support",
      "cache_write.active_support",
      "cache_delete.active_support",
      "cache_exist?.active_support",
      "cache_fetch_hit.active_support",
      "cache_generate.active_support",
      "cache_read_multi.active_support",
      "cache_write_multi.active_support"
    ].freeze

    def self.subscribe!
      EVENTS.each do |event_name|
        ActiveSupport::Notifications.subscribe(event_name) do |name, started, finished, _unique_id, data|
          next unless Thread.current[THREAD_LOCAL_KEY]

          duration_ms = ((finished - started) * 1000.0).round(2)
          event = build_event(name, data, duration_ms)
          if event && should_continue_tracking?
            Thread.current[THREAD_LOCAL_KEY] << event
          end
        end
      rescue
      end
    rescue
      # Never raise from instrumentation install
    end

    def self.start_request_tracking
      Thread.current[THREAD_LOCAL_KEY] = []
    end

    def self.stop_request_tracking
      events = Thread.current[THREAD_LOCAL_KEY]
      Thread.current[THREAD_LOCAL_KEY] = nil
      events || []
    end

    # Check if we should continue tracking based on count and time limits
    def self.should_continue_tracking?
      events = Thread.current[THREAD_LOCAL_KEY]
      return false unless events

      # Check count limit
      return false if events.length >= MAX_TRACKED_EVENTS

      # Check time limit
      start_time = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
      if start_time
        elapsed_seconds = Time.now - start_time
        return false if elapsed_seconds >= DeadBro::MAX_TRACKING_DURATION_SECONDS
      end

      true
    end

    def self.build_event(name, data, duration_ms)
      return nil unless data.is_a?(Hash)

      {
        event: name,
        duration_ms: duration_ms,
        key: safe_key(data[:key]),
        keys_count: safe_keys_count(data[:keys]),
        hit: infer_hit(name, data),
        store: safe_store_name(data[:store]),
        namespace: safe_namespace(data[:namespace]),
        at: Time.now.utc.to_i
      }
    rescue
      nil
    end

    def self.safe_key(key)
      return nil if key.nil?
      s = key.to_s
      (s.length > 200) ? s[0, 200] + "…" : s
    rescue
      nil
    end

    def self.safe_keys_count(keys)
      if keys.respond_to?(:size)
        keys.size
      end
    rescue
      nil
    end

    def self.safe_store_name(store)
      return nil unless store
      if store.respond_to?(:name)
        store.name
      else
        store.class.name
      end
    rescue
      nil
    end

    def self.safe_namespace(ns)
      ns.to_s[0, 100]
    rescue
      nil
    end

    def self.infer_hit(name, data)
      case name
      when "cache_fetch_hit.active_support"
        true
      when "cache_read.active_support"
        !!data[:hit]
      end
    rescue
      nil
    end
  end
end
