# frozen_string_literal: true

require "digest"
require "active_support/notifications"

module DeadBro
  class Subscriber
    EVENT_NAME = "process_action.action_controller"
    # The notification fields build_payload reads (see capture_request).
    PAYLOAD_KEYS = %i[controller action format method path status params view_runtime db_runtime request_id cache_hits cache_misses exception exception_object].freeze

    def self.subscribe!(client: Client.new)
      ActiveSupport::Notifications.subscribe(EVENT_NAME) do |name, started, finished, _unique_id, data|
        # When disabled remotely, fire a heartbeat at most once per minute so the gem
        # can detect when tracking has been re-enabled, then skip all tracking.
        unless DeadBro.configuration.enabled
          client.post_heartbeat if DeadBro.configuration.heartbeat_due?
          drain_request_tracking
          next
        end

        if DeadBro.configuration.skip_tracking?
          client.post_heartbeat if DeadBro.configuration.heartbeat_due?
          drain_request_tracking
          next
        end

        # Skip excluded controllers or controller#action pairs
        # Also check exclusive_controller_actions - if defined, only track those
        notification = data.is_a?(Hash) ? data : {}
        controller_name = notification[:controller].to_s
        action_name = notification[:action].to_s
        begin
          if DeadBro.configuration.excluded_controller?(controller_name, action_name)
            drain_request_tracking
            next
          end
          unless DeadBro.configuration.exclusive_controller?(controller_name, action_name)
            drain_request_tracking
            next
          end
        rescue
          drain_request_tracking
          next
        end

        has_error = data[:exception] || data[:exception_object]
        request_type_key = "#{controller_name}##{action_name}"
        # Errors always ship regardless of sampling (this is what the docs promise).
        unless has_error || DeadBro.configuration.should_sample?(request_type_key)
          drain_request_tracking
          next
        end

        # Only reading is done here, on the host's request thread: everything
        # the request collected is handed over as references, and the payload
        # is built, sanitized and JSON-encoded on a dispatcher worker (see
        # RequestCapture#to_payload).
        capture = capture_request(started, finished, data)
        event_name = has_error ? error_event_name(data) : name
        # force: true — the sampling decision (global or per-request-type) was
        # already made above; client#post_metric must not re-roll it with the
        # global-only rate, which would silently override a per-type sample rate.
        client.post_metric(event_name: event_name, payload: capture, force: true)
      rescue *DeadBro::CONTAINED_ERRORS
        # Anything raised here would fail the host's request (see
        # DeadBro::CONTAINED_ERRORS) — drop this request's metrics instead.
        drain_request_tracking
      end
    end

    # What a sampled request leaves for the dispatcher: what the trackers
    # collected and the values only the request thread can read. The payload is
    # built from it on a dispatcher worker (build_payload).
    RequestCapture = Struct.new(
      :data, :started, :duration_ms, :rack_duration_ms, :queue_duration_ms,
      :sql_aggregates, :transaction_events, :cache_events, :redis_events, :elasticsearch_events,
      :db_connection_wait_ms, :db_connection_checkouts, :sql_count, :gc_start, :gc_end,
      :ar_instantiation_count, :cpu_time_ms, :view_aggregates, :watch_events, :allocation_phases,
      :memory_usage, :memory_events, :memory_performance, :memory_frame, :memory_end_time,
      :http_events, :user_agent, :request_host, :user_id, :logs
    ) do
      # Called by the dispatcher worker (Client#post_metric).
      def to_payload
        Subscriber.build_payload(self)
      end
    end

    # Runs on the request thread: stops every tracker and keeps what it
    # collected, unsorted and unformatted.
    def self.capture_request(started, finished, data)
      capture = RequestCapture.new
      # Only the fields build_payload reads: the notification payload itself
      # holds the Rack env and the response, which a backed-up dispatcher queue
      # would keep alive.
      capture.data = data.slice(*PAYLOAD_KEYS)
      capture.started = started
      capture.duration_ms = ((finished - started) * 1000.0).round(2)

      # Time spent in Rack middleware before ActionController took over (routing, session, auth, etc.)
      rack_start = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
      capture.rack_duration_ms = rack_start ? ([((started - rack_start) * 1000.0), 0].max).round(2) : nil
      capture.queue_duration_ms = Thread.current[:dead_bro_queue_duration_ms]

      # Stop SQL tracking and get collected queries (this was started by the request)
      capture.sql_aggregates = DeadBro::SqlSubscriber.stop_request_tracking(sorted: false)
      capture.transaction_events = DeadBro::SqlSubscriber.last_transaction_events

      # Stop cache, redis, and elasticsearch tracking
      capture.cache_events = defined?(DeadBro::CacheSubscriber) ? DeadBro::CacheSubscriber.stop_request_tracking : []
      capture.redis_events = defined?(DeadBro::RedisSubscriber) ? DeadBro::RedisSubscriber.stop_request_tracking : []
      capture.elasticsearch_events = defined?(DeadBro::ElasticsearchSubscriber) ? DeadBro::ElasticsearchSubscriber.stop_request_tracking : []

      # Stop DB connection pool wait tracking
      if defined?(DeadBro::DbConnectionSubscriber)
        capture.db_connection_wait_ms = DeadBro::DbConnectionSubscriber.wait_ms
        capture.db_connection_checkouts = DeadBro::DbConnectionSubscriber.checkouts
        DeadBro::DbConnectionSubscriber.reset
      end
      # Read here: it asks this thread's ActiveRecord connection. After the
      # checkout counters above stopped, so its lease isn't counted.
      capture.sql_count = sql_count(data)

      # GC pressure — one snapshot closes the request; the worker diffs it
      capture.gc_start = DeadBro::GcTracker.take_start
      capture.gc_end = DeadBro::GcTracker.snapshot

      # Stop AR object instantiation tracking
      capture.ar_instantiation_count = defined?(DeadBro::ArObjectTracker) ? DeadBro::ArObjectTracker.stop_request_tracking : nil

      # Stop CPU time tracking — thread CPU time consumed by this request
      capture.cpu_time_ms = defined?(DeadBro::CpuTracker) ? DeadBro::CpuTracker.stop_request_tracking : nil

      # Stop view rendering tracking and get collected view events
      capture.view_aggregates = DeadBro::ViewRenderingSubscriber.take_aggregates

      capture.watch_events = defined?(DeadBro::WatchTracker) ? DeadBro::WatchTracker.stop_request_tracking : []

      # Per-phase allocation attribution (under memory tracking) — which phase
      # allocated the request's objects (sql / view / elasticsearch).
      capture.allocation_phases = if DeadBro.configuration.memory_tracking_enabled && defined?(DeadBro::MemoryPhaseTracker)
        DeadBro::MemoryPhaseTracker.stop_request_tracking
      else
        {}
      end

      capture.memory_usage = memory_usage_mb
      # Stop memory tracking and get collected memory data. The decision to do
      # heavy allocation tracking was made (and sampled) at request start.
      if Thread.current[:dead_bro_alloc_active] && defined?(DeadBro::MemoryTrackingSubscriber)
        detailed_memory = DeadBro::MemoryTrackingSubscriber.stop_request_tracking
        memory_performance = DeadBro::MemoryTrackingSubscriber.analyze_memory_performance(detailed_memory)

        # Allocation-source + by-bytes-type diagnostics. Read the trace data
        # before stopping the sampler (stop clears the source locations).
        if defined?(DeadBro::AllocationSourceSampler)
          growth = (detailed_memory[:memory_after].to_f - detailed_memory[:memory_before].to_f)
          source_analysis = DeadBro::AllocationSourceSampler.analyze(memory_growth_mb: growth)
          DeadBro::AllocationSourceSampler.stop
          if source_analysis.is_a?(Hash) && source_analysis.any?
            memory_performance[:allocation_sources] = source_analysis[:by_source]
            memory_performance[:memsize_by_type] = source_analysis[:by_type_bytes]
            memory_performance[:allocation_sample_rate] = source_analysis[:sample_rate]
            memory_performance[:allocation_sources_skipped] = source_analysis[:skipped] if source_analysis[:skipped]
          end
        end

        # Keep memory_events compact and user-friendly (no large raw arrays)
        capture.memory_events = {
          memory_before: detailed_memory[:memory_before],
          memory_after: detailed_memory[:memory_after],
          duration_seconds: detailed_memory[:duration_seconds],
          allocations_count: (detailed_memory[:allocations] || []).length,
          memory_snapshots_count: (detailed_memory[:memory_snapshots] || []).length,
          large_objects_count: (detailed_memory[:large_objects] || []).length
        }
        capture.memory_performance = memory_performance
      else
        # The worker works the lightweight metrics out from these readings.
        capture.memory_frame = DeadBro::LightweightMemoryTracker.take_frame
        capture.memory_end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      capture.http_events = DeadBro::EventBuffer.stop(:dead_bro_http_events)
      capture.user_agent = safe_user_agent(data)
      capture.request_host = raw_request_host(data)
      capture.user_id = extract_user_id(data)
      capture.logs = DeadBro.logger.logs
      capture
    end

    # Runs on the dispatcher worker: the payload the listener used to build on
    # the request thread, from a RequestCapture.
    def self.build_payload(capture)
      data = capture.data
      duration_ms = capture.duration_ms
      rack_duration_ms = capture.rack_duration_ms
      sql_queries = DeadBro::SqlSubscriber.sort_aggregates(capture.sql_aggregates)
      transaction_events = capture.transaction_events
      cache_events = capture.cache_events
      redis_events = capture.redis_events
      elasticsearch_events = capture.elasticsearch_events
      db_connection_stats = {wait_ms: capture.db_connection_wait_ms&.round(2), checkouts: capture.db_connection_checkouts}
      gc_end = capture.gc_end || {}
      gc_pressure = capture.gc_start ? DeadBro::GcTracker.diff(capture.gc_start, gc_end) : {}
      gc_stats = gc_stats_from(gc_end)
      ar_instantiation_count = capture.ar_instantiation_count
      cpu_time_ms = capture.cpu_time_ms
      view_events = DeadBro::ViewRenderingSubscriber.sort_aggregates(capture.view_aggregates)
      view_performance = DeadBro::ViewRenderingSubscriber.analyze_view_performance(view_events)
      watch_events = capture.watch_events
      allocation_phases = capture.allocation_phases

      if capture.memory_events
        memory_events = capture.memory_events
        memory_performance = capture.memory_performance
      else
        lightweight_memory = DeadBro::LightweightMemoryTracker.result(capture.memory_frame,
          memory_after: capture.memory_usage, gc_count_after: gc_stats[:count] || 0,
          heap_pages_after: gc_stats[:heap_allocated_pages] || 0, finished_at: capture.memory_end_time)
        # Separate raw readings from derived performance metrics to avoid duplicating data
        memory_events = {
          memory_before: lightweight_memory[:memory_before],
          memory_after: lightweight_memory[:memory_after]
        }
        memory_performance = {
          memory_growth_mb: lightweight_memory[:memory_growth_mb],
          gc_count_increase: lightweight_memory[:gc_count_increase],
          heap_pages_increase: lightweight_memory[:heap_pages_increase],
          duration_seconds: lightweight_memory[:duration_seconds]
        }
      end

      # Record memory sample for leak detection (only if memory tracking enabled),
      # at most once a minute per process.
      if DeadBro.configuration.memory_tracking_enabled && DeadBro::MemoryLeakDetector.sample_due?
        DeadBro::MemoryLeakDetector.record_memory_sample({
          memory_usage: capture.memory_usage,
          gc_count: gc_stats[:count],
          heap_pages: gc_stats[:heap_allocated_pages],
          object_count: gc_stats[:heap_live_slots],
          request_id: data[:request_id],
          controller: data[:controller],
          action: data[:action]
        })
      end

      # Everything captured during the request regardless of outcome — shared between
      # the error and success payloads below so an errored request (e.g. a lock wait
      # timeout raised mid-transaction) still ships the SQL/cache/memory/etc data that
      # led up to it, not just the exception. This used to be built only for the
      # success path, so every errored request shipped with sql_count: 0 and no trace
      # even though the gem had already captured it.
      detail_fields = {
        view_runtime_ms: data[:view_runtime],
        db_runtime_ms: data[:db_runtime],
        memory_usage: capture.memory_usage,
        gc_stats: gc_stats,
        sql_count: capture.sql_count,
        sql_queries: sql_queries,
        transaction_events: transaction_events,
        http_outgoing: capture.http_events || [],
        cache_events: cache_events,
        redis_events: redis_events,
        elasticsearch_events: elasticsearch_events,
        cache_hits: cache_hits(data),
        cache_misses: cache_misses(data),
        view_events: view_events,
        view_performance: view_performance,
        memory_events: memory_events,
        memory_performance: memory_performance,
        allocation_phases: allocation_phases,
        rack_duration_ms: rack_duration_ms,
        queue_duration_ms: capture.queue_duration_ms,
        db_connection_wait_ms: db_connection_stats[:wait_ms],
        db_connection_checkouts: db_connection_stats[:checkouts],
        gc_pressure: gc_pressure,
        ar_instantiation_count: ar_instantiation_count,
        cpu_time_ms: cpu_time_ms,
        watch_events: watch_events,
        logs: capture.logs
      }

      # Report exceptions attached to this action (e.g. controller/view errors)
      if data[:exception] || data[:exception_object]
        exception_class, exception_message = data[:exception] if data[:exception]
        exception_obj = data[:exception_object]
        backtrace = Array(exception_obj&.backtrace).first(50).map { |line| sanitize_string(line) }

        error_payload = detail_fields.merge(
          controller: data[:controller],
          action: data[:action],
          format: data[:format],
          method: data[:method],
          path: safe_path(data),
          status: data[:status],
          duration_ms: duration_ms,
          rails_env: DeadBro.env,
          host: DeadBro.safe_hostname,
          request_host: normalize_request_host(capture.request_host),
          process_kind: DeadBro.process_kind,
          params: safe_params(data),
          user_agent: capture.user_agent,
          user_id: capture.user_id,
          exception_class: exception_class || exception_obj&.class&.name,
          message: sanitize_string((exception_message || exception_obj&.message).to_s[0, 1000]),
          backtrace: backtrace,
          fingerprint: compute_error_fingerprint(exception_obj),
          cause_chain: build_cause_chain(exception_obj),
          error: true
        )
        return error_payload
      end

      payload = detail_fields.merge(
        controller: data[:controller],
        action: data[:action],
        format: data[:format],
        method: data[:method],
        path: safe_path(data),
        status: data[:status],
        # getutc, not utc: Time#utc converts in place, and other listeners of
        # this event got the same Time object.
        started_at: capture.started.getutc.iso8601(3),
        duration_ms: duration_ms,
        host: DeadBro.safe_hostname,
        request_host: normalize_request_host(capture.request_host),
        rails_env: DeadBro.env,
        process_kind: DeadBro.process_kind,
        params: safe_params(data),
        user_agent: capture.user_agent,
        user_id: capture.user_id
      )
      payload
    end

    def self.error_event_name(data)
      exception_class, = data[:exception] if data[:exception]
      (exception_class || data[:exception_object]&.class&.name || "exception").to_s
    end

    # Release per-subscriber thread-local state when we've decided not to build
    # a payload (disabled / excluded / sampled out). Without this, a subsequent
    # request reusing the same Puma thread would see stale queries/events.
    def self.drain_request_tracking
      # wait_for_explains: false — the result is discarded, so don't block this
      # thread waiting on pending EXPLAIN plans.
      # stop_request_tracking also pops the transaction-events stack (see its comment).
      DeadBro::SqlSubscriber.stop_request_tracking(wait_for_explains: false, sorted: false) if defined?(DeadBro::SqlSubscriber)
      DeadBro::CacheSubscriber.stop_request_tracking if defined?(DeadBro::CacheSubscriber)
      DeadBro::RedisSubscriber.stop_request_tracking if defined?(DeadBro::RedisSubscriber)
      DeadBro::ElasticsearchSubscriber.stop_request_tracking if defined?(DeadBro::ElasticsearchSubscriber)
      DeadBro::ViewRenderingSubscriber.take_aggregates if defined?(DeadBro::ViewRenderingSubscriber)
      DeadBro::LightweightMemoryTracker.take_frame if defined?(DeadBro::LightweightMemoryTracker)
      DeadBro::MemoryPhaseTracker.stop_request_tracking if defined?(DeadBro::MemoryPhaseTracker)
      if Thread.current[:dead_bro_alloc_active]
        DeadBro::MemoryTrackingSubscriber.stop_request_tracking if defined?(DeadBro::MemoryTrackingSubscriber)
        DeadBro::AllocationSourceSampler.stop if defined?(DeadBro::AllocationSourceSampler)
      end
      Thread.current[:dead_bro_alloc_active] = nil
      DeadBro::EventBuffer.stop(:dead_bro_http_events)
      DeadBro::DbConnectionSubscriber.reset if defined?(DeadBro::DbConnectionSubscriber)
      DeadBro::GcTracker.take_start if defined?(DeadBro::GcTracker)
      DeadBro::ArObjectTracker.stop_request_tracking if defined?(DeadBro::ArObjectTracker)
      DeadBro::CpuTracker.stop_request_tracking if defined?(DeadBro::CpuTracker)
      DeadBro::WatchTracker.stop_request_tracking if defined?(DeadBro::WatchTracker)
    rescue
      # Best effort — draining must never raise from the notifications callback.
    end

    def self.safe_path(data)
      path = data[:path] || (data[:request] && data[:request].path)
      sanitize_string(path)
    rescue
      ""
    end

    def self.safe_params(data)
      return {} unless data[:params]

      params = data[:params]
      begin
        params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      rescue
      end

      unless params.is_a?(Hash)
        return {}
      end

      # Remove router-provided keys that we already send at top-level
      router_keys = %w[controller action format]

      filtered = params.dup
      router_keys.each { |k| filtered.delete(k) || filtered.delete(k.to_sym) }

      # Truncate deeply to keep payload small and safe. truncate_value also redacts
      # sensitive keys at every nesting level (e.g. user[password]).
      truncate_value(filtered)
    rescue
      {}
    end

    def self.sanitize_string(str)
      DeadBro::Sanitizer.string(str)
    end

    # Matched against a key segment (delimited by start/end, underscore, dash, or
    # bracket) so nested and prefixed/suffixed keys are caught — e.g. user[password],
    # access_token, client_secret — without redacting innocent keys like
    # passenger_count or cardinality.
    SENSITIVE_SEGMENT_RE = /(?:\A|[_\-\[])(password|passwd|secret|token|api_?key|access_?key|auth|authorization|credential|ssn|credit_?card|card_?number|cvv|cvc)(?:\z|[_\-\]])/i

    def self.sensitive_key?(key)
      SENSITIVE_SEGMENT_RE.match?(key.to_s)
    end

    # Recursively truncate values to reasonable sizes to avoid huge payloads, and
    # redact values whose key looks sensitive at any nesting level.
    def self.truncate_value(value, max_str: 200, max_array: 20, max_hash_keys: 30)
      case value
      when String
        sanitized = sanitize_string(value)
        (sanitized.length > max_str) ? sanitized[0, max_str] + "…" : sanitized
      when Numeric, TrueClass, FalseClass, NilClass
        value
      when Array
        value[0, max_array].map { |v| truncate_value(v, max_str: max_str, max_array: max_array, max_hash_keys: max_hash_keys) }
      when Hash
        entries = value.to_a[0, max_hash_keys]
        entries.each_with_object({}) do |(k, v), memo|
          # Scrubbed first: the sensitive-key regex raises on a key that isn't
          # valid UTF-8, which would drop the whole params hash.
          k = sanitize_string(k) if k.is_a?(String)
          memo[k] = sensitive_key?(k) ? "[FILTERED]" : truncate_value(v, max_str: max_str, max_array: max_array, max_hash_keys: max_hash_keys)
        end
      else
        (value.to_s.length > max_str) ? value.to_s[0, max_str] + "…" : value.to_s
      end
    end

    # The domain the request was served on (request.host) — distinct from `host`,
    # which is the machine's OS hostname. Lets one app that answers on several
    # domains be sliced by domain in the dashboard. Port and userinfo are dropped;
    # value is lowercased so "Example.com" and "example.com" aren't two rows.
    def self.safe_request_host(data)
      normalize_request_host(raw_request_host(data))
    end

    # The host as the request reports it (ActionDispatch::Request#host when
    # there is a request) — read on the request thread, cleaned up later by
    # normalize_request_host.
    def self.raw_request_host(data)
      if data[:request] && data[:request].respond_to?(:host)
        data[:request].host
      elsif data[:headers]
        headers = data[:headers]
        if headers.respond_to?(:[])
          headers["HTTP_HOST"] || headers["Host"] || headers["host"]
        elsif headers.respond_to?(:env)
          headers.env && headers.env["HTTP_HOST"]
        end
      elsif data[:env].is_a?(Hash)
        data[:env]["HTTP_HOST"]
      end
    rescue
      nil
    end

    def self.normalize_request_host(raw)
      host = sanitize_string(raw)
      return "" if host.empty?

      # Strip any userinfo@ and a trailing :port so only the hostname remains.
      # Only a numeric trailing port is removed, so IPv6 literals ([::1]) survive.
      host = host.split("@").last.to_s
      host = host.sub(/:\d+\z/, "")
      host.downcase[0, 255]
    rescue
      ""
    end

    def self.safe_user_agent(data)
      begin
        # Prefer request object if available
        if data[:request]
          ua = nil
          if data[:request].respond_to?(:user_agent)
            ua = data[:request].user_agent
          elsif data[:request].respond_to?(:env)
            ua = data[:request].env && data[:request].env["HTTP_USER_AGENT"]
          end
          return sanitize_string(ua)[0..200]
        end

        # Fallback to headers object/hash if present in notification data
        if data[:headers]
          headers = data[:headers]
          if headers.respond_to?(:[])
            ua = headers["HTTP_USER_AGENT"] || headers["User-Agent"] || headers["user-agent"]
            return sanitize_string(ua)[0..200]
          elsif headers.respond_to?(:to_h)
            h = begin
              headers.to_h
            rescue
              {}
            end
            ua = h["HTTP_USER_AGENT"] || h["User-Agent"] || h["user-agent"]
            return sanitize_string(ua)[0..200]
          end
        end

        # Fallback to env hash if present in notification data
        if data[:env].is_a?(Hash)
          ua = data[:env]["HTTP_USER_AGENT"]
          return sanitize_string(ua)[0..200]
        end

        ""
      rescue
        ""
      end
    rescue
      ""
    end

    def self.memory_usage_mb
      DeadBro::MemoryHelpers.rss_mb
    rescue
      0
    end

    def self.gc_stats
      gc_stats_from(DeadBro::GcTracker.snapshot)
    end

    # The gc_stats payload field, from a GcTracker snapshot. heap_sorted_pages
    # stays in for older backends; Ruby 3.4+ no longer reports it (0).
    def self.gc_stats_from(snapshot)
      return {} if snapshot.nil? || snapshot.empty?

      {
        count: (snapshot[:minor_gc_count] || 0) + (snapshot[:major_gc_count] || 0),
        heap_allocated_pages: snapshot[:heap_allocated_pages] || 0,
        heap_sorted_pages: snapshot[:heap_sorted_pages] || 0,
        total_allocated_objects: snapshot[:total_allocated_objects] || 0
      }
    end

    def self.sql_count(data)
      # Count SQL queries from the payload if available
      if data[:sql_count]
        data[:sql_count]
      elsif defined?(ActiveRecord) && ActiveRecord::Base.connection
        # Try to get from ActiveRecord connection
        begin
          ActiveRecord::Base.connection.query_cache.size
        rescue
          0
        end
      else
        0
      end
    rescue
      0
    end

    def self.cache_hits(data)
      if data[:cache_hits]
        data[:cache_hits]
      elsif defined?(Rails) && Rails.cache.respond_to?(:stats)
        begin
          Rails.cache.stats[:hits]
        rescue
          0
        end
      else
        0
      end
    rescue
      0
    end

    def self.cache_misses(data)
      if data[:cache_misses]
        data[:cache_misses]
      elsif defined?(Rails) && Rails.cache.respond_to?(:stats)
        begin
          Rails.cache.stats[:misses]
        rescue
          0
        end
      else
        0
      end
    rescue
      0
    end

    # The signed-in user's id when Warden (Devise) is in the stack. Reads
    # request.env (ActionDispatch::Http::Headers#env copies it) and checks for
    # nil instead of rescuing the NoMethodError that no Warden or nobody signed
    # in used to raise on every request.
    def self.extract_user_id(data)
      request = data[:request]
      env = request.env if request.respond_to?(:env)
      env ||= data[:headers].env if data[:headers].respond_to?(:env)
      warden = env["warden"] if env.is_a?(Hash)
      return nil unless warden

      user = warden.user
      user.id if user.respond_to?(:id)
    rescue
      nil
    end

    def self.normalize_error_message(msg)
      sanitize_string(msg)
        .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "UUID")
        .gsub(/\b\d+\b/, "N")
        .gsub(/"[^"]*"/, '"?"')
        .gsub(/'[^']*'/, "'?'")
        .strip
    end

    def self.compute_error_fingerprint(exception)
      return nil unless exception
      top_frame = sanitize_string(Array(exception.backtrace).first).gsub(/:\d+:in /, ":N:in ")
      input = "#{exception.class.name}|#{normalize_error_message(exception.message)}|#{top_frame}"
      Digest::SHA256.hexdigest(input)[0, 16]
    rescue
      nil
    end

    def self.build_cause_chain(exception)
      return [] unless exception
      chain = []
      cause = exception.cause
      depth = 0
      while cause && depth < 5
        chain << {
          exception_class: cause.class.name,
          message: sanitize_string(cause.message.to_s[0, 500]),
          backtrace_top: Array(cause.backtrace).first(3).map { |line| sanitize_string(line) }
        }
        cause = cause.cause
        depth += 1
      end
      chain
    rescue
      []
    end
  end
end
