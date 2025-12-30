# frozen_string_literal: true

require "active_support/notifications"

module DeadBro
  class ViewRenderingSubscriber
    # Rails view rendering events
    RENDER_TEMPLATE_EVENT = "render_template.action_view"
    RENDER_PARTIAL_EVENT = "render_partial.action_view"
    RENDER_COLLECTION_EVENT = "render_collection.action_view"

    THREAD_LOCAL_KEY = :dead_bro_view_events

    def self.subscribe!(client: Client.new)
      # Track template rendering
      ActiveSupport::Notifications.subscribe(RENDER_TEMPLATE_EVENT) do |name, started, finished, _unique_id, data|
        duration_ms = ((finished - started) * 1000.0).round(2)

        view_info = {
          type: "template",
          identifier: safe_identifier(data[:identifier]),
          layout: data[:layout],
          duration_ms: duration_ms,
          virtual_path: data[:virtual_path],
          rendered_at: Time.now.utc.to_i
        }

        add_view_event(view_info)
      end

      # Track partial rendering
      ActiveSupport::Notifications.subscribe(RENDER_PARTIAL_EVENT) do |name, started, finished, _unique_id, data|
        duration_ms = ((finished - started) * 1000.0).round(2)

        view_info = {
          type: "partial",
          identifier: safe_identifier(data[:identifier]),
          layout: data[:layout],
          duration_ms: duration_ms,
          virtual_path: data[:virtual_path],
          cache_key: data[:cache_key],
          rendered_at: Time.now.utc.to_i
        }

        add_view_event(view_info)
      end

      # Track collection rendering (for partials rendered in loops)
      ActiveSupport::Notifications.subscribe(RENDER_COLLECTION_EVENT) do |name, started, finished, _unique_id, data|
        duration_ms = ((finished - started) * 1000.0).round(2)

        view_info = {
          type: "collection",
          identifier: safe_identifier(data[:identifier]),
          layout: data[:layout],
          duration_ms: duration_ms,
          virtual_path: data[:virtual_path],
          cache_key: data[:cache_key],
          count: data[:count],
          cached_count: data[:cached_count],
          rendered_at: Time.now.utc.to_i
        }

        add_view_event(view_info)
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

    def self.add_view_event(view_info)
      if Thread.current[THREAD_LOCAL_KEY]
        Thread.current[THREAD_LOCAL_KEY] << view_info
      end
    end

    def self.safe_identifier(identifier)
      return "" unless identifier.is_a?(String)

      # Extract meaningful parts of the file path
      # e.g., "/app/views/users/show.html.erb" -> "users/show.html.erb"
      identifier.split("/").last(3).join("/")
    rescue
      identifier.to_s
    end

    # Analyze view rendering performance
    def self.analyze_view_performance(view_events)
      return {} if view_events.empty?

      total_duration = view_events.sum { |event| event[:duration_ms] }

      # Group by view type
      by_type = view_events.group_by { |event| event[:type] }

      # Find slowest views
      slowest_views = view_events.sort_by { |event| -event[:duration_ms] }.first(5)

      # Find most frequently rendered views
      view_frequency = view_events.group_by { |event| event[:identifier] }
        .transform_values(&:count)
        .sort_by { |_, count| -count }
        .first(5)

      # Calculate cache hit rates for partials
      partials = view_events.select { |event| event[:type] == "partial" }
      cache_hits = partials.count { |event| event[:cache_key] }
      cache_hit_rate = partials.any? ? (cache_hits.to_f / partials.count * 100).round(2) : 0

      # Collection rendering analysis
      collections = view_events.select { |event| event[:type] == "collection" }
      total_collection_items = collections.sum { |event| event[:count] || 0 }
      total_cached_items = collections.sum { |event| event[:cached_count] || 0 }
      collection_cache_hit_rate = (total_collection_items > 0) ?
        (total_cached_items.to_f / total_collection_items * 100).round(2) : 0

      {
        total_views_rendered: view_events.count,
        total_view_duration_ms: total_duration.round(2),
        average_view_duration_ms: (total_duration / view_events.count).round(2),
        by_type: by_type.transform_values(&:count),
        slowest_views: slowest_views.map { |view|
          {
            identifier: view[:identifier],
            duration_ms: view[:duration_ms],
            type: view[:type]
          }
        },
        most_frequent_views: view_frequency.map { |identifier, count|
          {
            identifier: identifier,
            count: count
          }
        },
        partial_cache_hit_rate: cache_hit_rate,
        collection_cache_hit_rate: collection_cache_hit_rate,
        total_collection_items: total_collection_items,
        total_cached_collection_items: total_cached_items
      }
    end
  end
end
