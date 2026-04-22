# frozen_string_literal: true

require_relative "dead_bro/version"

module DeadBro
  autoload :Configuration, "dead_bro/configuration"
  autoload :Client, "dead_bro/client"
  autoload :Dispatcher, "dead_bro/dispatcher"
  autoload :CircuitBreaker, "dead_bro/circuit_breaker"
  autoload :Collectors, "dead_bro/collectors"
  autoload :Subscriber, "dead_bro/subscriber"
  autoload :SqlSubscriber, "dead_bro/sql_subscriber"
  autoload :SqlTrackingMiddleware, "dead_bro/sql_tracking_middleware"
  autoload :CacheSubscriber, "dead_bro/cache_subscriber"
  autoload :RedisSubscriber, "dead_bro/redis_subscriber"
  autoload :ElasticsearchSubscriber, "dead_bro/elasticsearch_subscriber"
  autoload :ViewRenderingSubscriber, "dead_bro/view_rendering_subscriber"
  autoload :MemoryTrackingSubscriber, "dead_bro/memory_tracking_subscriber"
  autoload :MemoryLeakDetector, "dead_bro/memory_leak_detector"
  autoload :LightweightMemoryTracker, "dead_bro/lightweight_memory_tracker"
  autoload :MemoryHelpers, "dead_bro/memory_helpers"
  autoload :JobSubscriber, "dead_bro/job_subscriber"
  autoload :JobSqlTrackingMiddleware, "dead_bro/job_sql_tracking_middleware"
  autoload :Monitor, "dead_bro/monitor"
  autoload :MemoryDetails, "dead_bro/memory_details"
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
  # - breakdown of distinct SQL query patterns (count and total time)
  # - memory before/after and delta
  # - when detailed memory tracking is enabled, GC and allocation stats
  #
  # The return value of this method is a hash with the following keys:
  # - :label
  # - :total_time_ms
  # - :sql_count
  # - :sql_time_ms
  # - :sql_queries (array of distinct query patterns with counts and timings)
  # - :memory_before_mb
  # - :memory_after_mb
  # - :memory_delta_mb
  # - :memory_details (detailed GC/allocation stats when available)
  def self.analyze(label = nil, verbose: false)
    raise ArgumentError, "DeadBro.analyze requires a block" unless block_given?

    label ||= "block"

    # Lower Rails log level to DEBUG and enable ActiveRecord verbose_query_logs
    # so Rails' own SQL logging (including ↳ caller frames) is visible.
    original_log_level = nil
    original_verbose_query_logs = nil
    if verbose
      begin
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger.respond_to?(:level)
          original_log_level = Rails.logger.level
          Rails.logger.level = 0 # Logger::DEBUG
        end
      rescue
      end
      begin
        if defined?(ActiveRecord) && ActiveRecord.respond_to?(:verbose_query_logs)
          original_verbose_query_logs = ActiveRecord.verbose_query_logs
          ActiveRecord.verbose_query_logs = true
        end
      rescue
      end
    end

    # Capture baseline memory stats — config-independent, analyze is debug-only.
    gc_before = begin; GC.stat; rescue; {}; end
    memory_before_mb = begin; DeadBro::MemoryHelpers.rss_mb; rescue; 0.0; end
    object_counts_before = begin
      defined?(ObjectSpace) && ObjectSpace.respond_to?(:count_objects) ? ObjectSpace.count_objects.dup : {}
    rescue; {}; end

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

            raw_sql = data[:sql].to_s
            # Normalize SQL so identical logical queries group together
            normalized_sql = begin
              sql = DeadBro::SqlSubscriber.sanitize_sql(raw_sql)
              # Collapse whitespace
              sql = sql.gsub(/\s+/, " ").strip
              # Normalize numeric literals and quoted strings to '?'
              sql = sql.gsub(/=\s*\d+(\.\d+)?/i, "= ?")
              sql = sql.gsub(/=\s*'[^']*'/i, "= ?")
              sql
            rescue
              raw_sql.to_s.strip
            end

            query_type = begin
              raw_sql.strip.split.first.to_s.upcase
            rescue
              "SQL"
            end

            local_sql_queries << {duration_ms: duration_ms, sql: normalized_sql, query_type: query_type}
          end
      end
    rescue
      sql_notification_subscription = nil
    end

    block_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = nil

    begin
      yield
    rescue => e
      error = e
    ensure
      # Restore Rails log level before any output
      begin
        if verbose && original_log_level
          Rails.logger.level = original_log_level
        end
      rescue
      end
      begin
        if verbose && !original_verbose_query_logs.nil?
          ActiveRecord.verbose_query_logs = original_verbose_query_logs
        end
      rescue
      end

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

      # Group SQL queries by normalized pattern to show frequency and cost
      query_signatures = Hash.new { |h, k| h[k] = {count: 0, total_time_ms: 0.0, type: nil} }
      local_sql_queries.each do |q|
        sig = (q[:sql] || "UNKNOWN").to_s
        entry = query_signatures[sig]
        entry[:count] += 1
        entry[:total_time_ms] += (q[:duration_ms] || 0.0).to_f
        entry[:type] ||= q[:query_type]
      end

      top_query_signatures = query_signatures.sort_by { |_, data| -data[:count] }.first(3)

      # Capture post-block memory state — always, regardless of config.
      gc_after = begin; GC.stat; rescue; {}; end
      memory_after_mb = begin; DeadBro::MemoryHelpers.rss_mb; rescue; memory_before_mb; end
      object_counts_after = begin
        defined?(ObjectSpace) && ObjectSpace.respond_to?(:count_objects) ? ObjectSpace.count_objects.dup : {}
      rescue; {}; end

      memory_delta_mb = (memory_after_mb - memory_before_mb).round(2)

      # Large object scan — full ObjectSpace walk. analyze is debug-only, not hot path.
      large_objects = begin
        if defined?(ObjectSpace) && ObjectSpace.respond_to?(:each_object) && ObjectSpace.respond_to?(:memsize_of)
          found = []
          ObjectSpace.each_object do |obj|
            size = begin; ObjectSpace.memsize_of(obj); rescue; 0; end
            next unless size > 1_000_000
            klass = begin; obj.class.name || "Unknown"; rescue; "Unknown"; end
            found << {class_name: klass, size_mb: (size / 1_000_000.0).round(2)}
            break if found.length >= 50
          end
          found.sort_by { |h| -h[:size_mb] }
        else
          []
        end
      rescue; []; end

      detailed_memory_summary = DeadBro::MemoryDetails.build(
        gc_before: gc_before,
        gc_after: gc_after,
        memory_before_mb: memory_before_mb,
        memory_after_mb: memory_after_mb,
        object_counts_before: object_counts_before,
        object_counts_after: object_counts_after,
        large_objects: large_objects
      )

      sql_queries_segment = ""
      unless top_query_signatures.empty?
        formatted_queries = top_query_signatures.map do |sig, data|
          type = data[:type] || "SQL"
          count = data[:count]
          total_ms = data[:total_time_ms].round(2)
          "#{type} #{sig} (#{count}x, #{total_ms}ms)"
        end
        sql_queries_segment = ", sql_top_queries=[#{formatted_queries.join(" | ")}]"
      end

      warnings = detailed_memory_summary[:warnings]
      warnings_segment = warnings.any? ? ", warnings=[#{warnings.join(", ")}]" : ""
      summary = "Analysis for #{label} - total_time=#{total_time_ms}ms, " \
                "sql_queries=#{sql_count}, sql_time=#{sql_time_ms}ms, " \
                "memory_before=#{memory_before_mb.round(2)}MB, " \
                "memory_after=#{memory_after_mb.round(2)}MB, " \
                "memory_delta=#{memory_delta_mb}MB, " \
                "gc_collections=+#{detailed_memory_summary[:gc_collections]}, " \
                "heap_pages_added=+#{detailed_memory_summary[:heap_pages_added]}, " \
                "new_objects=+#{detailed_memory_summary[:new_objects]}" \
                "#{sql_queries_segment}#{warnings_segment}"

      begin
        DeadBro.logger.info(summary)
      rescue
        begin
          $stdout.puts("[DeadBro] #{summary}")
        rescue
        end
      end

      # Build structured result hash to return to the caller
      sql_queries_detail = query_signatures.map do |sig, data|
        {
          sql: sig,
          query_type: data[:type] || "SQL",
          count: data[:count],
          total_time_ms: data[:total_time_ms].round(2)
        }
      end

      analysis_result = {
        label: label,
        total_time_ms: total_time_ms,
        sql_count: sql_count,
        sql_time_ms: sql_time_ms,
        sql_queries: sql_queries_detail,
        memory_before_mb: memory_before_mb,
        memory_after_mb: memory_after_mb,
        memory_delta_mb: memory_delta_mb,
        memory_details: detailed_memory_summary,
        verbose: verbose
      }
    end

    raise error if error
    analysis_result
  end
end
