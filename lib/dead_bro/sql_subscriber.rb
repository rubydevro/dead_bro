# frozen_string_literal: true

begin
  require "active_support/notifications"
rescue LoadError
  # ActiveSupport not available
end

module DeadBro
  class SqlSubscriber
    SQL_EVENT_NAME = "sql.active_record"
    THREAD_LOCAL_KEY = :dead_bro_sql_queries
    THREAD_LOCAL_ALLOC_START_KEY = :dead_bro_sql_alloc_start
    THREAD_LOCAL_ALLOC_RESULTS_KEY = :dead_bro_sql_alloc_results
    THREAD_LOCAL_BACKTRACE_KEY = :dead_bro_sql_backtraces
    THREAD_LOCAL_EXPLAIN_PENDING_KEY = :dead_bro_explain_pending
    THREAD_LOCAL_CALL_COUNTS_KEY     = :dead_bro_sql_call_counts
    THREAD_LOCAL_AGGREGATES_KEY      = :dead_bro_sql_aggregates
    MAX_TRACKED_QUERIES = 1000

    # Number of identical queries within one request that triggers N+1 detection.
    N_PLUS_ONE_THRESHOLD = 5

    NORMALIZE_PARAM_RE   = /\$\d+/.freeze
    NORMALIZE_NUMERIC_RE = /\b\d+(\.\d+)?\b/.freeze
    NORMALIZE_IN_RE      = /\bIN\s*\([^)]+\)/i.freeze
    NORMALIZE_SPACE_RE   = /\s+/.freeze

    # Precompiled regexes used by sanitize_sql. Dynamic /.../i literals inside
    # a hot-path method allocate a fresh Regexp on every call — pinning them
    # here removes that allocation entirely.
    SENSITIVE_KV_QUOTED_RE = /\b(password|token|secret|key|ssn|credit_card)\s*=\s*['"][^'"]*['"]/i
    SENSITIVE_KV_BARE_RE   = /\b(password|token|secret|key|ssn|credit_card)\s*=\s*[^'",\s)]+/i
    WHERE_EQ_QUOTED_RE     = /WHERE\s+[^=]+=\s*['"][^'"]*['"]/i
    WHERE_EQ_QUOTED_INNER_RE = /=\s*['"][^'"]*['"]/
    SANITIZE_MAX_LENGTH    = 1000
    SANITIZE_SKIP_SENSITIVE_WHEN_NO_KEYWORDS = /password|token|secret|key|ssn|credit_card/i
    SANITIZE_SKIP_WHERE_WHEN_NO_KEYWORD = /WHERE/i

    # True when there is at least one active tracking context (e.g. for nested jobs).
    def self.tracking_active?
      stack = Thread.current[THREAD_LOCAL_KEY]
      stack.is_a?(Array) && stack.any?
    end

    # Current queries array (top of stack); nil if no active tracking.
    def self.current_queries_array
      stack = Thread.current[THREAD_LOCAL_KEY]
      return nil unless stack.is_a?(Array) && stack.any?
      stack.last
    end

    # Check if we should continue tracking based on count and time limits
    def self.should_continue_tracking?(current_queries_array, max_count)
      return false unless current_queries_array.is_a?(Array)

      # Check count limit
      return false if current_queries_array.length >= max_count

      # Check time limit
      start_time = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
      if start_time
        elapsed_seconds = Time.now - start_time
        return false if elapsed_seconds >= DeadBro::MAX_TRACKING_DURATION_SECONDS
      end

      true
    end

    def self.normalize_for_n_plus_one(sql)
      return "" unless sql.is_a?(String)
      s = sql.dup
      s.gsub!(NORMALIZE_PARAM_RE, "?")
      s.gsub!(NORMALIZE_NUMERIC_RE, "?")
      s.gsub!(NORMALIZE_IN_RE, "IN (?)")
      s.gsub!(NORMALIZE_SPACE_RE, " ")
      s.strip!
      s.downcase!
      s
    rescue
      sql.to_s.downcase
    end

    def self.subscribe!
      # Subscribe with a start/finish listener to measure allocations per query
      if ActiveSupport::Notifications.notifier.respond_to?(:subscribe)
        begin
          ActiveSupport::Notifications.notifier.subscribe(SQL_EVENT_NAME, SqlAllocListener.new)
        rescue
        end
      end

      ActiveSupport::Notifications.subscribe(SQL_EVENT_NAME) do |name, started, finished, _unique_id, data|
        next if data[:name] == "SCHEMA" || data[:name] == "CACHE" || data[:name] == "BEGIN" || data[:name] == "COMMIT" || data[:name] == "ROLLBACK" || data[:name] == "SAVEPOINT" || data[:name] == "RELEASE"
        # Only track queries that are part of the current request (top of stack for nested jobs)
        current = current_queries_array
        next unless current
        unique_id = _unique_id
        allocations = nil
        begin
          alloc_results = Thread.current[THREAD_LOCAL_ALLOC_RESULTS_KEY]
          allocations = alloc_results && alloc_results.delete(unique_id)
        rescue
        end

        duration_ms = ((finished - started) * 1000.0).round(2)
        original_sql = data[:sql]

        threshold = begin
          DeadBro.configuration.slow_query_threshold_ms
        rescue
          500
        end
        sanitized_sql  = sanitize_sql(original_sql)
        captured_trace = (duration_ms >= threshold.to_f) ? capture_app_backtrace : []

        cc_stack     = Thread.current[THREAD_LOCAL_CALL_COUNTS_KEY]
        agg_stack    = Thread.current[THREAD_LOCAL_AGGREGATES_KEY]
        call_counts  = cc_stack.is_a?(Array)  ? cc_stack.last  : nil
        aggregates_h = agg_stack.is_a?(Array) ? agg_stack.last : nil
        normalized_key = nil

        if call_counts && aggregates_h
          normalized_key = normalize_for_n_plus_one(sanitized_sql)
          call_counts[normalized_key] = (call_counts[normalized_key] || 0) + 1
          # Capture backtrace exactly at the N+1 boundary — the stack is still meaningful here.
          if call_counts[normalized_key] == N_PLUS_ONE_THRESHOLD && captured_trace.empty?
            captured_trace = capture_app_backtrace
          end
        end

        query_info = {
          sql: sanitized_sql,
          name: data[:name],
          duration_ms: duration_ms,
          cached: data[:cached] || false,
          connection_id: data[:connection_id],
          trace: captured_trace,
          allocations: allocations
        }

        if should_explain_query?(duration_ms, original_sql)
          query_info[:explain_plan] = nil
          binds = data[:type_casted_binds] || data[:binds]
          start_explain_analyze_background(original_sql, data[:connection_id], query_info, binds)
        end

        if aggregates_h && normalized_key
          call_count = call_counts[normalized_key]
          if (agg = aggregates_h[normalized_key])
            agg[:count]             += 1
            agg[:total_duration_ms]  = (agg[:total_duration_ms] + duration_ms).round(2)
            agg[:max_duration_ms]    = [agg[:max_duration_ms], duration_ms].max
            agg[:min_duration_ms]    = [agg[:min_duration_ms], duration_ms].min
            agg[:total_allocations] += (allocations || 0)
            agg[:cached_count]      += 1 if query_info[:cached]
            agg[:n_plus_one]         = true if call_count >= N_PLUS_ONE_THRESHOLD
            agg[:backtrace]          = captured_trace if agg[:backtrace].empty? && !captured_trace.empty?
          else
            aggregates_h[normalized_key] = {
              sql:               sanitized_sql,
              name:              data[:name],
              count:             1,
              total_duration_ms: duration_ms,
              max_duration_ms:   duration_ms,
              min_duration_ms:   duration_ms,
              total_allocations: allocations || 0,
              cached_count:      (data[:cached] ? 1 : 0),
              n_plus_one:        false,
              backtrace:         captured_trace,
              explain_plan:      nil
            }
          end
        end

        if should_continue_tracking?(current, MAX_TRACKED_QUERIES)
          current << query_info
        end
      end
    end

    def self.start_request_tracking
      # Stack allows nested job tracking (e.g. one job performing others in the same thread)
      (Thread.current[THREAD_LOCAL_KEY] ||= []) << []
      Thread.current[THREAD_LOCAL_ALLOC_START_KEY] = {}
      Thread.current[THREAD_LOCAL_ALLOC_RESULTS_KEY] = {}
      Thread.current[THREAD_LOCAL_BACKTRACE_KEY] = {}
      Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY] = []
      (Thread.current[THREAD_LOCAL_CALL_COUNTS_KEY] ||= []) << {}
      (Thread.current[THREAD_LOCAL_AGGREGATES_KEY]  ||= []) << {}
    end

    def self.stop_request_tracking
      wait_for_pending_explains(EXPLAIN_WAIT_TIMEOUT_SECONDS)

      stack = Thread.current[THREAD_LOCAL_KEY]
      raw_queries = (stack.is_a?(Array) && stack.any?) ? stack.pop : []

      agg_stack    = Thread.current[THREAD_LOCAL_AGGREGATES_KEY]
      aggregates_h = (agg_stack.is_a?(Array) && agg_stack.any?) ? agg_stack.pop : {}
      cc_stack     = Thread.current[THREAD_LOCAL_CALL_COUNTS_KEY]
      cc_stack.pop if cc_stack.is_a?(Array) && cc_stack.any?

      # Fold any completed EXPLAIN plans from raw queries into their aggregate entry
      raw_queries.each do |q|
        next unless q[:explain_plan]
        key = normalize_for_n_plus_one(q[:sql].to_s)
        agg = aggregates_h[key]
        agg[:explain_plan] ||= q[:explain_plan] if agg
      end

      if stack.nil? || stack.empty?
        Thread.current[THREAD_LOCAL_KEY] = nil
        Thread.current[THREAD_LOCAL_ALLOC_START_KEY] = nil
        Thread.current[THREAD_LOCAL_ALLOC_RESULTS_KEY] = nil
        Thread.current[THREAD_LOCAL_BACKTRACE_KEY] = nil
        Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
        Thread.current[THREAD_LOCAL_CALL_COUNTS_KEY] = nil
        Thread.current[THREAD_LOCAL_AGGREGATES_KEY]  = nil
      end

      aggregates_h.values.sort_by { |a| -a[:total_duration_ms] }
    end

    # Upper bound on pending EXPLAIN threads per request — stops a slow-query
    # storm from spawning unbounded background threads.
    MAX_PENDING_EXPLAINS = 20
    # Overall wall-clock we're willing to block the request thread for pending
    # EXPLAINs. If the plan isn't ready by then, skip it rather than stall the request.
    EXPLAIN_WAIT_TIMEOUT_SECONDS = 5.0

    def self.wait_for_pending_explains(timeout_seconds)
      pending = Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY]
      return unless pending && !pending.empty?

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pending.each do |thread|
        remaining_time = timeout_seconds - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
        break if remaining_time <= 0

        begin
          thread.join(remaining_time)
        rescue => e
          DeadBro.logger.debug("Error waiting for EXPLAIN ANALYZE: #{e.message}")
        end
      end
    end

    def self.sanitize_sql(sql)
      return sql unless sql.is_a?(String)

      # Cap length first — most "expensive" queries from the app's perspective
      # are big UPDATE/INSERT with long literal blobs; don't burn regex time on
      # those when we're going to truncate anyway.
      sql = sql[0..SANITIZE_MAX_LENGTH] + "..." if sql.length > SANITIZE_MAX_LENGTH

      # Only scan for sensitive KV pairs if one of the keywords is actually
      # present — saves two regex passes on the vast majority of queries.
      if sql.match?(SANITIZE_SKIP_SENSITIVE_WHEN_NO_KEYWORDS)
        sql = sql.gsub(SENSITIVE_KV_QUOTED_RE, '\1 = ?')
        sql = sql.gsub(SENSITIVE_KV_BARE_RE, '\1 = ?')
      end

      # Same short-circuit for WHERE rewrite.
      if sql.match?(SANITIZE_SKIP_WHERE_WHEN_NO_KEYWORD)
        sql = sql.gsub(WHERE_EQ_QUOTED_RE) do |match|
          match.gsub(WHERE_EQ_QUOTED_INNER_RE, "= ?")
        end
      end

      sql
    end

    def self.should_explain_query?(duration_ms, sql)
      return false unless DeadBro.configuration.explain_analyze_enabled
      return false if duration_ms < DeadBro.configuration.slow_query_threshold_ms
      return false unless sql.is_a?(String)
      return false if sql.strip.empty?

      # Skip EXPLAIN for certain query types that don't benefit from it
      sql_upper = sql.upcase.strip
      return false if sql_upper.start_with?("EXPLAIN")
      return false if sql_upper.start_with?("BEGIN")
      return false if sql_upper.start_with?("COMMIT")
      return false if sql_upper.start_with?("ROLLBACK")
      return false if sql_upper.start_with?("SAVEPOINT")
      return false if sql_upper.start_with?("RELEASE")

      true
    end

    def self.start_explain_analyze_background(sql, connection_id, query_info, binds = nil)
      return unless defined?(ActiveRecord)
      return unless ActiveRecord::Base.respond_to?(:connection)

      # Cap pending EXPLAINs per request. A slow-query storm that would have
      # spawned 200 threads and starved the AR pool now drops excess plans
      # instead of cascading into a timeout.
      pending = Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY] ||= []
      if pending.length >= MAX_PENDING_EXPLAINS
        query_info[:explain_plan] = nil
        return
      end

      # Capture the main thread reference to append logs to the correct thread
      main_thread = Thread.current

      # Run EXPLAIN in a background thread to avoid blocking the main request.
      # We use `with_connection` so the connection returns to the pool even if
      # the thread is killed or the block raises — the previous manual
      # checkout/checkin could leak a connection under pathological paths.
      explain_thread = Thread.new do
        begin
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            final_sql = interpolate_sql_with_binds(sql, binds, connection)
            explain_sql = build_explain_query(final_sql, connection)

            adapter_name = connection.adapter_name.downcase
            result = if adapter_name == "postgresql" || adapter_name == "postgis"
              connection.select_all(explain_sql)
            else
              connection.execute(explain_sql)
            end

            explain_plan = format_explain_result(result, connection)
            query_info[:explain_plan] = if explain_plan && !explain_plan.to_s.strip.empty?
              explain_plan
            end
          end
        rescue => e
          # Silently fail — don't let EXPLAIN break the application.
          append_log_to_thread(main_thread, :debug, "Failed to capture EXPLAIN ANALYZE: #{e.message}")
          query_info[:explain_plan] = nil
        end
      end

      pending << explain_thread
    rescue => e
      # Use DeadBro.logger here since we're still in the main thread
      DeadBro.logger.debug("Failed to start EXPLAIN ANALYZE thread: #{e.message}")
    end

    # Append a log entry directly to a specific thread's log storage
    # This is used when logging from background threads to ensure logs
    # are collected with the main request thread's logs
    def self.append_log_to_thread(thread, severity, message)
      timestamp = Time.now.utc
      log_entry = {
        sev: severity.to_s,
        msg: message.to_s,
        time: timestamp.iso8601(3)
      }

      # Append to the specified thread's log storage
      thread[:dead_bro_logs] ||= []
      thread[:dead_bro_logs] << log_entry

      # Also print the message immediately (using current thread's logger)
      begin
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          formatted_message = "[DeadBro] #{timestamp.iso8601(3)} #{severity.to_s.upcase}: #{message}"
          case severity
          when :debug
            Rails.logger.debug(formatted_message)
          when :info
            Rails.logger.info(formatted_message)
          when :warn
            Rails.logger.warn(formatted_message)
          when :error
            Rails.logger.error(formatted_message)
          when :fatal
            Rails.logger.fatal(formatted_message)
          end
        else
          # Fallback to stdout
          $stdout.puts("[DeadBro] #{timestamp.iso8601(3)} #{severity.to_s.upcase}: #{message}")
        end
      rescue
        # Never let logging break the application
        $stdout.puts("[DeadBro] #{severity.to_s.upcase}: #{message}")
      end
    end

    def self.build_explain_query(sql, connection)
      adapter_name = connection.adapter_name.downcase

      case adapter_name
      when "postgresql", "postgis"
        # PostgreSQL supports ANALYZE and BUFFERS
        "EXPLAIN (ANALYZE, BUFFERS) #{sql}"
      when "mysql", "mysql2", "trilogy"
        # MySQL uses different syntax - ANALYZE is a separate keyword
        "EXPLAIN ANALYZE #{sql}"
      when "sqlite3"
        # SQLite supports EXPLAIN QUERY PLAN
        "EXPLAIN QUERY PLAN #{sql}"
      else
        # Generic fallback - just EXPLAIN
        "EXPLAIN #{sql}"
      end
    end

    def self.interpolate_sql_with_binds(sql, binds, connection)
      return sql if binds.nil? || binds.empty?
      return sql unless connection

      interpolated_sql = sql.dup

      # Handle $1, $2 style placeholders (PostgreSQL)
      if interpolated_sql.include?("$1")
        binds.each_with_index do |val, index|
          # Get value from bind param (handle both raw values and ActiveRecord::Relation::QueryAttribute)
          value = val
          if val.respond_to?(:value_for_database)
            value = val.value_for_database
          elsif val.respond_to?(:value)
            value = val.value
          end

          quoted_value = connection.quote(value)
          interpolated_sql = interpolated_sql.gsub("$#{index + 1}", quoted_value)
        end
      elsif interpolated_sql.include?("?")
        # Handle ? style placeholders (MySQL, SQLite)
        # We need to replace ? one by one in order
        binds.each do |val|
          # Get value from bind param
          value = val
          if val.respond_to?(:value_for_database)
            value = val.value_for_database
          elsif val.respond_to?(:value)
            value = val.value
          end

          quoted_value = connection.quote(value)
          interpolated_sql = interpolated_sql.sub("?", quoted_value)
        end
      end

      interpolated_sql
    end

    def self.format_explain_result(result, connection)
      adapter_name = connection.adapter_name.downcase

      case adapter_name
      when "postgresql", "postgis"
        # PostgreSQL returns ActiveRecord::Result from select_all
        if result.respond_to?(:rows)
          # ActiveRecord::Result object - rows is an array of arrays
          # Each row is [query_plan_string]
          plan_text = result.rows.map { |row| row.is_a?(Array) ? row.first.to_s : row.to_s }.join("\n")
          return plan_text unless plan_text.strip.empty?
        end

        # Try alternative methods to extract the plan
        if result.respond_to?(:each) && result.respond_to?(:columns)
          # ActiveRecord::Result with columns
          plan_column = result.columns.find { |col| col.downcase.include?("plan") || col.downcase.include?("query") } || result.columns.first
          plan_text = result.map { |row|
            if row.is_a?(Hash)
              row[plan_column] || row[plan_column.to_sym] || row.values.first
            else
              row
            end
          }.join("\n")
          return plan_text unless plan_text.strip.empty?
        end

        if result.is_a?(Array)
          # Array of hashes or arrays
          plan_text = result.map do |row|
            if row.is_a?(Hash)
              row["QUERY PLAN"] || row["query plan"] || row[:query_plan] || row.values.first.to_s
            elsif row.is_a?(Array)
              row.first.to_s
            else
              row.to_s
            end
          end.join("\n")
          return plan_text unless plan_text.strip.empty?
        end

        # Fallback to string representation
        result.to_s
      when "mysql", "mysql2", "trilogy"
        # MySQL returns Mysql2::Result object which needs to be converted to array
        if result.respond_to?(:to_a)
          # Convert Mysql2::Result to array of hashes
          rows = result.to_a
          rows.map { |row| row.is_a?(Hash) ? row.values.join(" | ") : row.to_s }.join("\n")
        elsif result.is_a?(Array)
          result.map { |row| row.is_a?(Hash) ? row.values.join(" | ") : row.to_s }.join("\n")
        else
          result.to_s
        end
      when "sqlite3"
        # SQLite returns rows
        if result.is_a?(Array)
          result.map { |row| row.is_a?(Hash) ? row.values.join(" | ") : row.to_s }.join("\n")
        else
          result.to_s
        end
      else
        # Generic fallback
        result.to_s
      end
    rescue
      # Fallback to string representation
      result.to_s
    end

    APP_BACKTRACE_MAX_FRAMES = 25
    APP_BACKTRACE_SENSITIVE_RE = /\/[^\/]*(password|secret|key|token)[^\/]*\//i

    # Cheap app-only backtrace for the current query. Uses caller_locations
    # (lazy frame objects, no string allocations until we render) and keeps
    # only frames under app/ (filtering vendor/). Returns at most N frames.
    def self.capture_app_backtrace
      locations = caller_locations(1, 100) || []
      frames = []
      locations.each do |loc|
        path = loc.path.to_s
        next unless path.include?("app/")
        next if path.include?("/vendor/")
        frames << "#{path}:#{loc.lineno}:in `#{loc.label}'".gsub(APP_BACKTRACE_SENSITIVE_RE, "/[FILTERED]/")
        break if frames.length >= APP_BACKTRACE_MAX_FRAMES
      end
      frames
    rescue
      []
    end

    def self.safe_query_trace(data, captured_backtrace = nil)
      return [] unless data.is_a?(Hash)

      # Build trace from available data fields
      trace = []

      # Use filename, line, and method if available
      if data[:filename] && data[:line] && data[:method]
        trace << "#{data[:filename]}:#{data[:line]}:in `#{data[:method]}'"
      end

      # Use the captured backtrace from when the query started (most accurate)
      if captured_backtrace && captured_backtrace.is_a?(Array) && !captured_backtrace.empty?
        # Filter to only include frames that contain "app/" (application code)
        app_frames = captured_backtrace.select do |frame|
          frame.include?("app/") && !frame.include?("/vendor/")
        end

        caller_trace = app_frames.map do |line|
          # Remove any potential sensitive information from file paths
          line.gsub(/\/[^\/]*(password|secret|key|token)[^\/]*\//i, "/[FILTERED]/")
        end

        trace.concat(caller_trace)
      else
        # Fallback: try to get backtrace from current context
        begin
          # Get all available frames - we'll filter to find application code
          all_frames = Thread.current.backtrace || []

          if all_frames.empty?
            # Fallback to caller_locations if backtrace is empty
            locations = caller_locations(1, 50)
            all_frames = locations.map { |loc| "#{loc.path}:#{loc.lineno}:in `#{loc.label}'" } if locations
          end

          # Filter to only include frames that contain "app/" (application code)
          app_frames = all_frames.select do |frame|
            frame.include?("app/") && !frame.include?("/vendor/")
          end

          caller_trace = app_frames.map do |line|
            line.gsub(/\/[^\/]*(password|secret|key|token)[^\/]*\//i, "/[FILTERED]/")
          end

          trace.concat(caller_trace)
        rescue
          # If backtrace fails, try caller as fallback
          begin
            caller_stack = caller(20, 50) # Get more frames to find app/ frames
            app_frames = caller_stack.select { |frame| frame.include?("app/") && !frame.include?("/vendor/") }
            caller_trace = app_frames.map do |line|
              line.gsub(/\/[^\/]*(password|secret|key|token)[^\/]*\//i, "/[FILTERED]/")
            end
            trace.concat(caller_trace)
          rescue
            # If caller also fails, we still have the immediate location
          end
        end
      end

      # If we have a backtrace in the data, use it (but it's usually nil for SQL events)
      if data[:backtrace] && data[:backtrace].is_a?(Array)
        # Filter to only include frames that contain "app/"
        app_backtrace = data[:backtrace].select do |line|
          line.is_a?(String) && line.include?("app/") && !line.include?("/vendor/")
        end

        backtrace_trace = app_backtrace.map do |line|
          case line
          when String
            line.gsub(/\/[^\/]*(password|secret|key|token)[^\/]*\//i, "/[FILTERED]/")
          else
            line.to_s
          end
        end
        trace.concat(backtrace_trace)
      end

      # Remove duplicates and return all app/ frames (no limit)
      trace.uniq.map do |line|
        case line
        when String
          # Remove any potential sensitive information from file paths
          line.gsub(/\/[^\/]*(password|secret|key|token)[^\/]*\//i, "/[FILTERED]/")
        else
          line.to_s
        end
      end
    rescue
      []
    end
  end
end

module DeadBro
  # Listener that records GC allocation deltas per SQL event id
  class SqlAllocListener
    def start(name, id, payload)
      map = (Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_ALLOC_START_KEY] ||= {})
      map[id] = GC.stat[:total_allocated_objects] if defined?(GC) && GC.respond_to?(:stat)
      # Backtraces used to be captured here for every SQL event, which was
      # dominating CPU on N+1-heavy requests (100s of full Thread#backtrace
      # allocations). The main subscriber now captures a trimmed backtrace
      # lazily — and only when a query exceeds slow_query_threshold_ms.
    rescue
    end

    def finish(name, id, payload)
      start_map = Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_ALLOC_START_KEY]
      return unless start_map && start_map.key?(id)

      start_count = start_map.delete(id)
      end_count = begin
        GC.stat[:total_allocated_objects]
      rescue
        nil
      end
      return unless start_count && end_count

      delta = end_count - start_count
      results = (Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_ALLOC_RESULTS_KEY] ||= {})
      results[id] = delta
    rescue
    end
  end
end
