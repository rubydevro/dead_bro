# frozen_string_literal: true

require "active_support/notifications"

module DeadBro
  class ViewRenderingSubscriber
    RENDER_TEMPLATE_EVENT  = "render_template.action_view"
    RENDER_PARTIAL_EVENT   = "render_partial.action_view"
    RENDER_COLLECTION_EVENT = "render_collection.action_view"

    THREAD_LOCAL_KEY            = :dead_bro_view_events
    THREAD_LOCAL_AGGREGATES_KEY = :dead_bro_view_aggregates
    MAX_TRACKED_EVENTS = 500

    def self.subscribe!(client: Client.new)
      ActiveSupport::Notifications.subscribe(RENDER_TEMPLATE_EVENT) do |_name, started, finished, _uid, data|
        add_view_event(type: "template", identifier: safe_identifier(data[:identifier]),
                       duration_ms: ((finished - started) * 1000.0).round(2),
                       rendered_at: Time.now.utc.to_i)
      end

      ActiveSupport::Notifications.subscribe(RENDER_PARTIAL_EVENT) do |_name, started, finished, _uid, data|
        add_view_event(type: "partial", identifier: safe_identifier(data[:identifier]),
                       duration_ms: ((finished - started) * 1000.0).round(2),
                       cache_key: data[:cache_key],
                       rendered_at: Time.now.utc.to_i)
      end

      ActiveSupport::Notifications.subscribe(RENDER_COLLECTION_EVENT) do |_name, started, finished, _uid, data|
        add_view_event(type: "collection", identifier: safe_identifier(data[:identifier]),
                       duration_ms: ((finished - started) * 1000.0).round(2),
                       collection_count: (data[:count] || 0).to_i,
                       collection_cached_count: (data[:cached_count] || 0).to_i,
                       rendered_at: Time.now.utc.to_i)
      end
    rescue
    end

    def self.start_request_tracking
      Thread.current[THREAD_LOCAL_KEY]            = true
      Thread.current[THREAD_LOCAL_AGGREGATES_KEY] = {}
    end

    def self.stop_request_tracking
      Thread.current[THREAD_LOCAL_KEY] = nil
      aggregates = Thread.current[THREAD_LOCAL_AGGREGATES_KEY] || {}
      Thread.current[THREAD_LOCAL_AGGREGATES_KEY] = nil
      aggregates.values.sort_by { |a| [-a[:count], -a[:total_duration_ms]] }
    end

    def self.add_view_event(view_info)
      return unless Thread.current[THREAD_LOCAL_KEY]
      aggregates = Thread.current[THREAD_LOCAL_AGGREGATES_KEY]
      return unless aggregates

      key = view_info[:identifier].to_s
      dur = view_info[:duration_ms].to_f
      rendered_at = view_info[:rendered_at]

      if (agg = aggregates[key])
        agg[:count]                   += 1
        agg[:total_duration_ms]        = (agg[:total_duration_ms] + dur).round(2)
        agg[:max_duration_ms]          = [agg[:max_duration_ms], dur].max
        agg[:min_duration_ms]          = [agg[:min_duration_ms], dur].min
        agg[:rendered_at_min]          = [agg[:rendered_at_min], rendered_at].compact.min if rendered_at
        agg[:rendered_at_max]          = [agg[:rendered_at_max], rendered_at].compact.max if rendered_at
        agg[:cache_hit_count]         += 1 if view_info[:cache_key]
        agg[:collection_count]        += view_info[:collection_count].to_i
        agg[:collection_cached_count] += view_info[:collection_cached_count].to_i
      else
        return if aggregates.size >= MAX_TRACKED_EVENTS
        aggregates[key] = {
          identifier:              key,
          type:                    view_info[:type],
          count:                   1,
          total_duration_ms:       dur,
          max_duration_ms:         dur,
          min_duration_ms:         dur,
          rendered_at_min:         rendered_at,
          rendered_at_max:         rendered_at,
          cache_hit_count:         (view_info[:cache_key] ? 1 : 0),
          collection_count:        view_info[:collection_count].to_i,
          collection_cached_count: view_info[:collection_cached_count].to_i
        }
      end
    end

    def self.safe_identifier(identifier)
      return "" unless identifier.is_a?(String)
      identifier.split("/").last(3).join("/")
    rescue
      identifier.to_s
    end

    def self.analyze_view_performance(view_events)
      return {} if view_events.empty?

      total_renders  = view_events.sum { |e| e_int(e, :count, 1) }
      total_duration = view_events.sum { |e| e_flt(e, :total_duration_ms) }

      by_type = Hash.new(0)
      view_events.each { |e| by_type[e_str(e, :type)] += e_int(e, :count, 1) }

      slowest = view_events.sort_by { |e| -e_flt(e, :max_duration_ms) }.first(5).map do |e|
        { identifier: e_str(e, :identifier), duration_ms: e_flt(e, :max_duration_ms), type: e_str(e, :type) }
      end

      most_frequent = view_events.sort_by { |e| -e_int(e, :count, 1) }.first(5).map do |e|
        { identifier: e_str(e, :identifier), count: e_int(e, :count, 1) }
      end

      partials                = view_events.select { |e| e_str(e, :type) == "partial" }
      total_partial_renders   = partials.sum { |e| e_int(e, :count, 1) }
      total_cache_hits        = partials.sum { |e| e_int(e, :cache_hit_count) }
      partial_cache_hit_rate  = total_partial_renders > 0 ? (total_cache_hits.to_f / total_partial_renders * 100).round(2) : 0

      collections            = view_events.select { |e| e_str(e, :type) == "collection" }
      total_collection_items = collections.sum { |e| e_int(e, :collection_count) }
      total_cached_items     = collections.sum { |e| e_int(e, :collection_cached_count) }
      collection_cache_hit_rate = total_collection_items > 0 ? (total_cached_items.to_f / total_collection_items * 100).round(2) : 0

      {
        total_views_rendered:           total_renders,
        total_view_duration_ms:         total_duration.round(2),
        average_view_duration_ms:       total_renders > 0 ? (total_duration / total_renders).round(2) : 0,
        by_type:                        by_type,
        slowest_views:                  slowest,
        most_frequent_views:            most_frequent,
        partial_cache_hit_rate:         partial_cache_hit_rate,
        collection_cache_hit_rate:      collection_cache_hit_rate,
        total_collection_items:         total_collection_items,
        total_cached_collection_items:  total_cached_items
      }
    end

    private

    def self.e_int(e, key, default = 0)
      (e[key] || e[key.to_s] || default).to_i
    end

    def self.e_flt(e, key, default = 0.0)
      (e[key] || e[key.to_s] || default).to_f
    end

    def self.e_str(e, key, default = "")
      (e[key] || e[key.to_s] || default).to_s
    end
  end
end
