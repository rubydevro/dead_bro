# frozen_string_literal: true

require "json"

module DeadBro
  # Wraps the optional `stackprof` gem to capture a sampled call-stack profile
  # for a single request. stackprof is an OPTIONAL dependency: it is a Linux-only
  # C extension, so it is soft-required here and every public method is a no-op
  # when it is unavailable. Nothing in this file may raise into the host app.
  #
  # stackprof exposes a single global profiler, so :wall and :object modes cannot
  # run at the same time. We alternate the mode per profiled request (see
  # .pick_mode) so an endpoint accumulates both kinds of profile over time.
  module Profiler
    # Sampling interval per mode (stackprof defaults): wall is microseconds of
    # wall-clock between samples; object is allocations between samples.
    MODE_INTERVALS = {wall: 1000, object: 1}.freeze
    MODES = [:wall, :object].freeze

    # Number of top self-heavy frames kept in the gem-side summary.
    SUMMARY_TOP_FRAMES = 15

    # Thread-local holding the active mode for the in-flight request. Set by the
    # middleware after a successful start; read + cleared when the profile is
    # collected (Subscriber) or discarded (drain / middleware safety net).
    MODE_KEY = :dead_bro_profile_mode

    AVAILABLE = begin
      # stackprof relies on Linux-only signal/timer APIs; skip the require
      # entirely elsewhere so dev machines (macOS) stay a clean no-op.
      if RUBY_PLATFORM.include?("linux")
        require "stackprof"
        defined?(::StackProf) ? true : false
      else
        false
      end
    rescue LoadError, StandardError
      false
    end

    @mode_counter = 0
    @mode_mutex = Mutex.new

    module_function

    def available?
      AVAILABLE
    end

    # Alternate :wall / :object so both kinds of profile accumulate per endpoint.
    # Thread-safe; the decision is made once per request at request start.
    def pick_mode
      @mode_mutex.synchronize do
        mode = MODES[@mode_counter % MODES.length]
        @mode_counter += 1
        mode
      end
    end

    # Begin profiling. Returns true when the profiler was actually started.
    # Refuses to start a nested session (stackprof is a single global profiler).
    def start(mode)
      return false unless available?
      return false if ::StackProf.running?

      interval = MODE_INTERVALS[mode] || MODE_INTERVALS[:wall]
      ::StackProf.start(mode: mode, raw: true, interval: interval, ignore_gc: true)
    rescue StandardError
      false
    end

    # Stop profiling and return the raw stackprof dump hash, or nil. Never raises.
    def stop
      return nil unless available?
      return nil unless ::StackProf.running?

      ::StackProf.stop
      ::StackProf.results
    rescue StandardError
      nil
    end

    def interval_for(mode)
      MODE_INTERVALS[mode] || MODE_INTERVALS[:wall]
    end

    # Build a small, queryable summary from a stackprof dump so list views and
    # the MCP tool never have to read/parse the full raw blob. Returns a Hash
    # with the total sample count and the top self-heavy frames.
    def summarize(dump, mode:, interval:, top: SUMMARY_TOP_FRAMES)
      return nil unless dump.is_a?(Hash)

      frames = dump[:frames] || dump["frames"] || {}
      sample_count = (dump[:samples] || dump["samples"] || 0).to_i

      top_frames = frames.values.map { |f|
        next nil unless f.is_a?(Hash)
        {
          name: (f[:name] || f["name"]).to_s,
          samples: (f[:samples] || f["samples"] || 0).to_i,
          total_samples: (f[:total_samples] || f["total_samples"] || 0).to_i
        }
      }.compact.sort_by { |f| -f[:samples] }.first(top)

      {
        mode: mode.to_s,
        interval: interval,
        sample_count: sample_count,
        top_frames: top_frames
      }
    rescue StandardError
      nil
    end

    # Stop the in-flight profile (started by the middleware) and build the
    # payload hash attached to the request: always the small summary, plus the
    # raw dump unless it would exceed max_bytes once serialized. Returns nil when
    # this request was not being profiled. Called from the process_action
    # subscriber so the profile boundary matches controller + view rendering.
    def collect(max_bytes: nil)
      mode = Thread.current[MODE_KEY]
      return nil unless mode

      dump = stop
      Thread.current[MODE_KEY] = nil
      return nil unless dump

      interval = interval_for(mode)
      result = {
        mode: mode.to_s,
        interval: interval,
        summary: summarize(dump, mode: mode, interval: interval)
      }

      raw_json = (JSON.generate(dump) rescue nil)
      if raw_json.nil? || (max_bytes && raw_json.bytesize > max_bytes.to_i)
        # Too big (or unserializable) — keep the summary, drop the raw blob so a
        # huge profile never bloats the request payload.
        result[:raw_dropped] = true
        result[:raw_byte_size] = raw_json&.bytesize
      else
        result[:raw] = dump
        result[:raw_byte_size] = raw_json.bytesize
      end

      result
    rescue StandardError
      Thread.current[MODE_KEY] = nil
      nil
    end

    # Stop and throw away the in-flight profile (request sampled out / excluded /
    # disabled, or middleware safety net). Never raises.
    def discard
      Thread.current[MODE_KEY] = nil
      stop
      nil
    rescue StandardError
      nil
    end
  end
end
