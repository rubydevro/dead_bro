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

    def self.subscribe!
      # Subscribe with a start/finish listener to measure allocations per query
      if ActiveSupport::Notifications.notifier.respond_to?(:subscribe)
        begin
          ActiveSupport::Notifications.notifier.subscribe(SQL_EVENT_NAME, SqlAllocListener.new)
        rescue
        end
      end

      ActiveSupport::Notifications.subscribe(SQL_EVENT_NAME) do |name, started, finished, _unique_id, data|
        next if data[:name] == "SCHEMA"
        # Only track queries that are part of the current request
        next unless Thread.current[THREAD_LOCAL_KEY]
        unique_id = _unique_id
        allocations = nil
        captured_backtrace = nil
        begin
          alloc_results = Thread.current[THREAD_LOCAL_ALLOC_RESULTS_KEY]
          allocations = alloc_results && alloc_results.delete(unique_id)

          # Get the captured backtrace from when the query started
          backtrace_map = Thread.current[THREAD_LOCAL_BACKTRACE_KEY]
          captured_backtrace = backtrace_map && backtrace_map.delete(unique_id)
        rescue
        end

        duration_ms = ((finished - started) * 1000.0).round(2)
        original_sql = data[:sql]

        query_info = {
          sql: sanitize_sql(original_sql),
          name: data[:name],
          duration_ms: duration_ms,
          cached: data[:cached] || false,
          connection_id: data[:connection_id],
          trace: safe_query_trace(data, captured_backtrace),
          allocations: allocations
        }

        # Run EXPLAIN ANALYZE for slow queries in the background
        if should_explain_query?(duration_ms, original_sql)
          # Store reference to query_info so we can update it when EXPLAIN completes
          query_info[:explain_plan] = nil # Placeholder
          start_explain_analyze_background(original_sql, data[:connection_id], query_info)
        end

        # Add to thread-local storage
        Thread.current[THREAD_LOCAL_KEY] << query_info
      end
    end

    def self.start_request_tracking
      Thread.current[THREAD_LOCAL_KEY] = []
      Thread.current[THREAD_LOCAL_ALLOC_START_KEY] = {}
      Thread.current[THREAD_LOCAL_ALLOC_RESULTS_KEY] = {}
      Thread.current[THREAD_LOCAL_BACKTRACE_KEY] = {}
      Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY] = []
    end

    def self.stop_request_tracking
      # Wait for any pending EXPLAIN ANALYZE queries to complete (with timeout)
      # This must happen BEFORE we get the queries array reference to ensure
      # all explain_plan fields are populated
      wait_for_pending_explains(5.0) # 5 second timeout
      
      # Get queries after waiting for EXPLAIN to complete
      queries = Thread.current[THREAD_LOCAL_KEY]
      
      Thread.current[THREAD_LOCAL_KEY] = nil
      Thread.current[THREAD_LOCAL_ALLOC_START_KEY] = nil
      Thread.current[THREAD_LOCAL_ALLOC_RESULTS_KEY] = nil
      Thread.current[THREAD_LOCAL_BACKTRACE_KEY] = nil
      Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY] = nil
      queries || []
    end

    def self.wait_for_pending_explains(timeout_seconds)
      pending = Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY]
      return unless pending && !pending.empty?
      
      start_time = Time.now
      pending.each do |thread|
        remaining_time = timeout_seconds - (Time.now - start_time)
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

      # Remove sensitive data patterns
      sql = sql.gsub(/\b(password|token|secret|key|ssn|credit_card)\s*=\s*['"][^'"]*['"]/i, '\1 = ?')
      sql = sql.gsub(/\b(password|token|secret|key|ssn|credit_card)\s*=\s*[^'",\s)]+/i, '\1 = ?')

      # Remove specific values in WHERE clauses that might be sensitive
      sql = sql.gsub(/WHERE\s+[^=]+=\s*['"][^'"]*['"]/i) do |match|
        match.gsub(/=\s*['"][^'"]*['"]/, "= ?")
      end

      # Limit query length to prevent huge payloads
      (sql.length > 1000) ? sql[0..1000] + "..." : sql
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

    def self.start_explain_analyze_background(sql, connection_id, query_info)
      return unless defined?(ActiveRecord)
      return unless ActiveRecord::Base.respond_to?(:connection)
      
      # Capture the main thread reference to append logs to the correct thread
      main_thread = Thread.current
      
      # Run EXPLAIN in a background thread to avoid blocking the main request
      explain_thread = Thread.new do
        connection = nil
        begin
          # Use a separate connection to avoid interfering with the main query
          if ActiveRecord::Base.connection_pool.respond_to?(:checkout)
            connection = ActiveRecord::Base.connection_pool.checkout
          else
            connection = ActiveRecord::Base.connection
          end
          
          # Build EXPLAIN query based on database adapter
          explain_sql = build_explain_query(sql, connection)
          
          # Execute the EXPLAIN query
          # For PostgreSQL, use select_all which returns ActiveRecord::Result
          # For other databases, use execute
          adapter_name = connection.adapter_name.downcase
          if adapter_name == "postgresql" || adapter_name == "postgis"
            # PostgreSQL: select_all returns ActiveRecord::Result with rows
            result = connection.select_all(explain_sql)
          else
            # Other databases: use execute
            result = connection.execute(explain_sql)
          end
          
          # Format the result based on database adapter
          explain_plan = format_explain_result(result, connection)
          
          # Update the query_info with the explain plan
          # This updates the hash that's already in the queries array
          if explain_plan && !explain_plan.to_s.strip.empty?
            query_info[:explain_plan] = explain_plan
            append_log_to_thread(main_thread, :debug, "Captured EXPLAIN ANALYZE for slow query (#{query_info[:duration_ms]}ms): #{explain_plan[0..1000]}...")
          else
            query_info[:explain_plan] = nil
            append_log_to_thread(main_thread, :debug, "EXPLAIN ANALYZE returned empty result. Result type: #{result.class}, Result: #{result.inspect[0..200]}")
          end
        rescue => e
          # Silently fail - don't let EXPLAIN break the application
          append_log_to_thread(main_thread, :debug, "Failed to capture EXPLAIN ANALYZE: #{e.message}")
          query_info[:explain_plan] = nil
        ensure
          # Return connection to pool if we checked it out
          if connection && ActiveRecord::Base.connection_pool.respond_to?(:checkin)
            ActiveRecord::Base.connection_pool.checkin(connection) rescue nil
          end
        end
      end
      
      # Track the thread so we can wait for it when stopping request tracking
      pending = Thread.current[THREAD_LOCAL_EXPLAIN_PENDING_KEY] ||= []
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
        # MySQL returns rows
        if result.is_a?(Array)
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
    rescue => e
      # Fallback to string representation
      result.to_s
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

      # Capture the backtrace at query start time (before notification system processes it)
      # This gives us the actual call stack where the SQL was executed
      backtrace_map = (Thread.current[DeadBro::SqlSubscriber::THREAD_LOCAL_BACKTRACE_KEY] ||= {})
      captured_backtrace = Thread.current.backtrace
      if captured_backtrace && captured_backtrace.is_a?(Array)
        # Skip the first few frames (our listener code) to get to the actual query execution
        backtrace_map[id] = captured_backtrace[5..-1] || captured_backtrace
      end
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
