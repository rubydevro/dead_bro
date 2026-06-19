# frozen_string_literal: true

module DeadBro
  # Records user-defined timed blocks (DeadBro.watch) during an instrumented
  # request or background job. Spans include wall duration, nesting depth, and
  # SQL attributable to the block (delta from SqlSubscriber aggregates).
  #
  # Unlike DeadBro.analyze, watch spans are sent to the DeadBro backend as part
  # of the normal request/job payload when watch_enabled is on.
  module WatchTracker
    THREAD_LOCAL_EVENTS_KEY = :dead_bro_watch_events
    THREAD_LOCAL_ACTIVE_STACK_KEY = :dead_bro_watch_active_stack

    MAX_DEPTH = 10
    MAX_SPANS_PER_REQUEST = 50
    MAX_LABEL_LENGTH = 200
    MAX_TAGS = 5
    MAX_TAG_VALUE_LENGTH = 100

    module_function

    def enabled?
      DeadBro.configuration.watch_enabled?
    rescue StandardError
      false
    end

    def tracking_active?
      Thread.current[THREAD_LOCAL_EVENTS_KEY].is_a?(Array)
    rescue StandardError
      false
    end

    def start_request_tracking
      Thread.current[THREAD_LOCAL_EVENTS_KEY] = []
      Thread.current[THREAD_LOCAL_ACTIVE_STACK_KEY] = []
    end

    def stop_request_tracking
      events = Thread.current[THREAD_LOCAL_EVENTS_KEY]
      Thread.current[THREAD_LOCAL_EVENTS_KEY] = nil
      Thread.current[THREAD_LOCAL_ACTIVE_STACK_KEY] = nil
      events.is_a?(Array) ? events : []
    rescue StandardError
      []
    end

    def watch(label = nil, **tags)
      return yield unless block_given?
      return yield unless enabled?
      return yield unless tracking_active?

      events = Thread.current[THREAD_LOCAL_EVENTS_KEY]
      active_stack = Thread.current[THREAD_LOCAL_ACTIVE_STACK_KEY]
      return yield unless events.is_a?(Array) && active_stack.is_a?(Array)

      depth = active_stack.length
      return yield if depth >= MAX_DEPTH
      return yield if events.length >= MAX_SPANS_PER_REQUEST

      sanitized_label = sanitize_label(label)
      sanitized_tags = sanitize_tags(tags)
      start_offset_ms = compute_start_offset_ms
      sql_before = sql_metrics_snapshot
      block_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      frame = {
        label: sanitized_label,
        depth: depth,
        tags: sanitized_tags,
        start_offset_ms: start_offset_ms,
        sql_before: sql_before,
        block_start: block_start,
        error: false,
        exception_class: nil
      }
      active_stack << frame

      begin
        yield
      rescue StandardError => e
        frame[:error] = true
        frame[:exception_class] = e.class.name.to_s[0, 200]
        raise
      ensure
        active_stack.pop if active_stack.last.equal?(frame)
        append_completed_span(events, frame)
      end
    end

    def sanitize_label(label)
      text = label.to_s.strip
      text = "block" if text.empty?
      (text.length > MAX_LABEL_LENGTH) ? text[0, MAX_LABEL_LENGTH] + "..." : text
    rescue StandardError
      "block"
    end

    def sanitize_tags(tags)
      return {} unless tags.is_a?(Hash) && tags.any?

      tags.first(MAX_TAGS).each_with_object({}) do |(key, value), out|
        k = key.to_s.strip[0, 50]
        next if k.empty?

        v = value.to_s.strip
        v = v[0, MAX_TAG_VALUE_LENGTH] + "..." if v.length > MAX_TAG_VALUE_LENGTH
        out[k] = v
      end
    rescue StandardError
      {}
    end

    def compute_start_offset_ms
      tracking_start = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
      return 0.0 unless tracking_start

      ((Time.now - tracking_start) * 1000.0).round(2)
    rescue StandardError
      0.0
    end

    def sql_metrics_snapshot
      return {count: 0, duration_ms: 0.0} unless defined?(DeadBro::SqlSubscriber)

      DeadBro::SqlSubscriber.current_sql_metrics
    rescue StandardError
      {count: 0, duration_ms: 0.0}
    end

    def append_completed_span(events, frame)
      return unless events.is_a?(Array)
      return if events.length >= MAX_SPANS_PER_REQUEST

      elapsed_ms = begin
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - frame[:block_start]) * 1000.0).round(2)
      rescue StandardError
        0.0
      end

      sql_after = sql_metrics_snapshot
      sql_before = frame[:sql_before] || {count: 0, duration_ms: 0.0}
      sql_count = [(sql_after[:count] || 0).to_i - (sql_before[:count] || 0).to_i, 0].max
      sql_duration_ms = [
        (sql_after[:duration_ms] || 0.0).to_f - (sql_before[:duration_ms] || 0.0).to_f,
        0.0
      ].max.round(2)

      span = {
        label: frame[:label],
        duration_ms: elapsed_ms,
        start_offset_ms: frame[:start_offset_ms],
        depth: frame[:depth],
        sql_count: sql_count,
        sql_duration_ms: sql_duration_ms,
        error: frame[:error] == true
      }
      span[:exception_class] = frame[:exception_class] if frame[:exception_class]
      tags = frame[:tags]
      span[:tags] = tags if tags.is_a?(Hash) && tags.any?

      events << span
    rescue StandardError
      # Never raise from instrumentation
    end
  end
end
