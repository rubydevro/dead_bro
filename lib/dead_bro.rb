# frozen_string_literal: true

require_relative "dead_bro/version"

module DeadBro
  autoload :Configuration, "dead_bro/configuration"
  autoload :Client, "dead_bro/client"
  autoload :CircuitBreaker, "dead_bro/circuit_breaker"
  autoload :Collectors, "dead_bro/collectors"
  autoload :Subscriber, "dead_bro/subscriber"
  autoload :SqlSubscriber, "dead_bro/sql_subscriber"
  autoload :SqlTrackingMiddleware, "dead_bro/sql_tracking_middleware"
  autoload :CacheSubscriber, "dead_bro/cache_subscriber"
  autoload :RedisSubscriber, "dead_bro/redis_subscriber"
  autoload :ViewRenderingSubscriber, "dead_bro/view_rendering_subscriber"
  autoload :MemoryTrackingSubscriber, "dead_bro/memory_tracking_subscriber"
  autoload :MemoryLeakDetector, "dead_bro/memory_leak_detector"
  autoload :LightweightMemoryTracker, "dead_bro/lightweight_memory_tracker"
  autoload :MemoryHelpers, "dead_bro/memory_helpers"
  autoload :JobSubscriber, "dead_bro/job_subscriber"
  autoload :JobSqlTrackingMiddleware, "dead_bro/job_sql_tracking_middleware"
  autoload :Monitor, "dead_bro/monitor"
  autoload :Logger, "dead_bro/logger"
  begin
    require "dead_bro/railtie"
  rescue LoadError
  end

  class Error < StandardError; end

  def self.configure
    yield configuration
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.reset_configuration!
    @configuration = nil
    @client = nil
  end

  # Returns a shared Client instance for use across the application
  def self.client
    @client ||= Client.new
  end

  # Returns a process-stable deploy identifier used when none is configured.
  # Memoized per-Ruby process to avoid generating a new UUID per request.
  def self.process_deploy_id
    @process_deploy_id ||= begin
      require "securerandom"
      SecureRandom.uuid
    end
  end

  # Returns the logger instance for storing and retrieving log messages
  def self.logger
    @logger ||= Logger.new
  end

  # Returns the current environment (Rails.env or ENV fallback)
  def self.env
    if defined?(Rails) && Rails.respond_to?(:env)
      Rails.env
    else
      ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
    end
  rescue
    "development"
  end

  # Returns the monitor instance
  def self.monitor
    @monitor
  end

  # Sets the monitor instance
  def self.monitor=(monitor)
    @monitor = monitor
  end

  # Shared constant for tracking start time (used by all subscribers)
  TRACKING_START_TIME_KEY = :dead_bro_tracking_start_time
  MAX_TRACKING_DURATION_SECONDS = 3600 # 1 hour

  # Analyze a block of code by tracking its runtime, SQL queries, and memory usage.
  #
  # Usage:
  #   DeadBro.analyze("load users") do
  #     User.where(active: true).to_a
  #   end
  #
  # This will print a summary to the console (or Rails logger) including:
  # - total time the block took
  # - number of SQL queries executed
  # - total SQL time
  # - memory before/after and delta
  # - when detailed memory tracking is enabled, GC and allocation stats
  #
  # The return value of the block is returned unchanged from this method.
  def self.analyze(label = nil)
    raise ArgumentError, "DeadBro.analyze requires a block" unless block_given?

    label ||= "block"

    # Always prefer detailed memory tracking via MemoryTrackingSubscriber.
    # If detailed tracking is already active for this thread (e.g. inside a
    # request), we will NOT start/stop it again to avoid interfering – but we
    # still use its memory_usage_mb helper for before/after numbers.
    memory_tracking_started = false
    memory_before_mb = 0.0

    begin
      if defined?(DeadBro::MemoryTrackingSubscriber) &&
         !Thread.current[DeadBro::MemoryTrackingSubscriber::THREAD_LOCAL_KEY]
        DeadBro::MemoryTrackingSubscriber.start_request_tracking
        memory_tracking_started = true
      end
    rescue
    end

    begin
      if defined?(DeadBro::MemoryTrackingSubscriber)
        memory_before_mb = DeadBro::MemoryTrackingSubscriber.memory_usage_mb
      else
        memory_before_mb = 0.0
      end
    rescue
      memory_before_mb = 0.0
    end

    # Local SQL tracking just for this block.
    # We subscribe directly to ActiveSupport::Notifications instead of relying
    # on DeadBro's global SqlSubscriber tracking so we don't interfere with or
    # depend on request/job instrumentation.
    current_thread = Thread.current
    local_sql_queries = []
    sql_notification_subscription = nil

    begin
      if defined?(ActiveSupport) && defined?(ActiveSupport::Notifications)
        # Ensure SqlSubscriber is loaded so SQL_EVENT_NAME is defined
        DeadBro::SqlSubscriber
        event_name = DeadBro::SqlSubscriber::SQL_EVENT_NAME

        sql_notification_subscription =
          ActiveSupport::Notifications.subscribe(event_name) do |_name, started, finished, _id, data|
            # Only count queries executed on this thread and skip schema queries
            next unless Thread.current == current_thread
            next if data[:name] == "SCHEMA"

            duration_ms = begin
              ((finished - started) * 1000.0).round(2)
            rescue
              0.0
            end

            local_sql_queries << {
              duration_ms: duration_ms
            }
          end
      end
    rescue
      sql_notification_subscription = nil
    end

    block_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = nil
    result = nil

    begin
      result = yield
    rescue => e
      error = e
    ensure
      # Always unsubscribe our local SQL subscriber
      begin
        if sql_notification_subscription && defined?(ActiveSupport) && defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.unsubscribe(sql_notification_subscription)
        end
      rescue
      end

      total_time_ms = begin
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - block_start
        (elapsed * 1000.0).round(2)
      rescue
        0.0
      end

      # Aggregate SQL metrics from our local subscription
      sql_count = local_sql_queries.length
      sql_time_ms = local_sql_queries.sum { |q| (q[:duration_ms] || 0.0).to_f }.round(2)

      memory_after_mb = memory_before_mb
      memory_delta_mb = 0.0
      detailed_memory_summary = nil

      raw_events = {}
      if memory_tracking_started
        begin
          raw_events = DeadBro::MemoryTrackingSubscriber.stop_request_tracking || {}
        rescue
          raw_events = {}
        end
      end

      begin
        # Prefer values from detailed tracking when available
        if raw_events[:memory_before]
          memory_before_mb = raw_events[:memory_before]
        end

        if raw_events[:memory_after]
          memory_after_mb = raw_events[:memory_after]
        else
          if defined?(DeadBro::MemoryTrackingSubscriber)
            memory_after_mb = DeadBro::MemoryTrackingSubscriber.memory_usage_mb
          else
            memory_after_mb = memory_before_mb
          end
        end
      rescue
        memory_after_mb = memory_before_mb
      end

      memory_delta_mb = (memory_after_mb - memory_before_mb).round(2)

      if memory_tracking_started && !raw_events.empty?
        begin
          perf = DeadBro::MemoryTrackingSubscriber.analyze_memory_performance(raw_events) || {}

          detailed_memory_summary = {
            memory_growth_mb: (perf[:memory_growth_mb] || memory_delta_mb).to_f,
            gc_count_increase: perf.dig(:gc_efficiency, :gc_count_increase) || 0,
            heap_pages_increase: perf.dig(:gc_efficiency, :heap_pages_increase) || 0,
            total_allocated_size_mb: (perf[:total_allocated_size_mb] || 0.0).to_f,
            top_allocating_classes: (perf[:top_allocating_classes] || []).first(3)
          }
        rescue
          detailed_memory_summary = nil
        end
      end

      base_summary = "Analysis for #{label} - total_time=#{total_time_ms}ms, " \
                     "sql_queries=#{sql_count}, sql_time=#{sql_time_ms}ms, " \
                     "memory_before=#{memory_before_mb.round(2)}MB, " \
                     "memory_after=#{memory_after_mb.round(2)}MB, " \
                     "memory_delta=#{memory_delta_mb}MB"

      summary =
        if detailed_memory_summary
          top_classes = (detailed_memory_summary[:top_allocating_classes] || []).map { |c|
            "#{c[:class_name]}:#{c[:size_mb]}MB"
          }.join(", ")

          "#{base_summary}, " \
            "memory_growth=#{detailed_memory_summary[:memory_growth_mb].round(2)}MB, " \
            "gc_runs=+#{detailed_memory_summary[:gc_count_increase]}, " \
            "heap_pages=+#{detailed_memory_summary[:heap_pages_increase]}, " \
            "allocated=#{detailed_memory_summary[:total_allocated_size_mb].round(2)}MB, " \
            "top_allocators=[#{top_classes}]"
        else
          base_summary
        end

      begin
        DeadBro.logger.info(summary)
      rescue
        begin
          $stdout.puts("[DeadBro] #{summary}")
        rescue
        end
      end
    end

    raise error if error
    result
  end
end
