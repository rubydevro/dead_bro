# frozen_string_literal: true

require "active_support/notifications"

module DeadBro
  # Attributes a request's object allocations to the phase that produced them —
  # e.g. "92% of this request's allocations happened during Elasticsearch".
  #
  # This is the always-on, low-overhead companion to GcTracker: GcTracker tells
  # you *how many* objects a request allocated and whether they were retained;
  # MemoryPhaseTracker tells you *where* they were allocated, so a 400MB request
  # can be localized to ES deserialization vs view rendering vs controller code
  # without running a full allocation profiler.
  #
  # Attribution is *exclusive*: a sql.active_record event nested inside a view
  # render is charged only to :sql, not to both. A thread-local stack records
  # the allocation counter when each phase becomes active; entering a child
  # phase flushes the parent's accumulated delta and pauses it, leaving the
  # child resumes the parent. Whatever isn't captured by an instrumented phase
  # stays "unattributed" (controller/application code) and is derivable on the
  # backend as gc_pressure.allocated_objects minus the sum of these buckets.
  module MemoryPhaseTracker
    THREAD_KEY = :dead_bro_memory_phases

    # ActiveSupport event name => phase bucket. Each maps to a coarse phase so
    # the breakdown stays readable (all view render events collapse to :view).
    EVENT_PHASES = {
      "sql.active_record" => :sql,
      "render_template.action_view" => :view,
      "render_partial.action_view" => :view,
      "render_collection.action_view" => :view,
      "render_layout.action_view" => :view,
      "request.elasticsearch" => :elasticsearch,
      "request.elastic_transport" => :elasticsearch
    }.freeze

    # Bridges ActiveSupport's evented-listener protocol (start/finish) onto our
    # enter/leave accounting. Registered once per event name at boot.
    class Listener
      def initialize(phase)
        @phase = phase
      end

      def start(_name, _id, _payload)
        MemoryPhaseTracker.enter(@phase)
      end

      def finish(_name, _id, _payload)
        MemoryPhaseTracker.leave(@phase)
      end
    end

    def self.subscribe!
      return if @subscribed
      @subscribed = true
      return unless allocation_counter_available?

      EVENT_PHASES.each do |event_name, phase|
        ActiveSupport::Notifications.subscribe(event_name, Listener.new(phase))
      end
    rescue StandardError
      # Never raise from instrumentation install.
    end

    def self.start_request_tracking
      Thread.current[THREAD_KEY] = {buckets: Hash.new(0), stack: []}
    end

    # Returns { sql: n, view: n, elasticsearch: n } of objects allocated
    # exclusively within each phase, omitting phases that allocated nothing.
    def self.stop_request_tracking
      state = Thread.current[THREAD_KEY]
      return {} unless state.is_a?(Hash)

      buckets = state[:buckets]
      buckets.each_with_object({}) do |(phase, count), result|
        result[phase] = count if count.positive?
      end
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    def self.enter(phase)
      state = Thread.current[THREAD_KEY]
      return unless state.is_a?(Hash)

      now = allocated_objects
      stack = state[:stack]
      if (parent = stack.last)
        # Pause the parent: bank what it allocated up to this point.
        state[:buckets][parent[:phase]] += now - parent[:checkpoint]
      end
      stack << {phase: phase, checkpoint: now}
    rescue StandardError
      # Best-effort only.
    end

    def self.leave(phase)
      state = Thread.current[THREAD_KEY]
      return unless state.is_a?(Hash)

      stack = state[:stack]
      frame = stack.pop
      return unless frame

      now = allocated_objects
      state[:buckets][frame[:phase]] += now - frame[:checkpoint]
      # Resume the parent from this point so the child's allocations aren't
      # double-counted into it.
      if (parent = stack.last)
        parent[:checkpoint] = now
      end
    rescue StandardError
      # Best-effort only.
    end

    # Single-key GC.stat returns just the Integer (no hash allocation), so this
    # is cheap enough to call on every instrumented event boundary.
    def self.allocated_objects
      GC.stat(:total_allocated_objects)
    rescue StandardError
      0
    end

    def self.allocation_counter_available?
      defined?(GC) && GC.respond_to?(:stat) && !GC.stat(:total_allocated_objects).nil?
    rescue StandardError
      false
    end
  end
end
