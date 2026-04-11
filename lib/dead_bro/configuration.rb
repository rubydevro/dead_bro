# frozen_string_literal: true

module DeadBro
  class Configuration
    # Local-only settings (not overwritten by API `settings` payloads).
    # Note: `enabled` may still be updated remotely via apply_remote_settings when the backend
    # returns it in a response; local configure() values apply until the next remote update.
    attr_accessor :api_key, :open_timeout, :read_timeout, :enabled, :ruby_dev,
      :circuit_breaker_enabled, :circuit_breaker_failure_threshold, :circuit_breaker_recovery_timeout,
      :circuit_breaker_retry_timeout, :deploy_id, :disk_paths, :interfaces_ignore

    # Remote-managed settings (overwritten by backend JSON `settings` on successful API responses)
    attr_accessor :memory_tracking_enabled, :allocation_tracking_enabled,
      :sample_rate, :excluded_controllers, :excluded_jobs,
      :exclusive_controllers, :exclusive_jobs, :slow_query_threshold_ms, :explain_analyze_enabled,
      :job_queue_monitoring_enabled, :enable_db_stats, :enable_process_stats, :enable_system_stats,
      :max_sql_queries_to_send, :max_logs_to_send

    # Tracks when we last received settings from the backend (in-memory only)
    attr_accessor :settings_received_at

    # Last successful heartbeat HTTP response time while disabled (in-memory only)
    attr_accessor :last_heartbeat_at

    # Throttles heartbeat attempts to HEARTBEAT_INTERVAL (set when a heartbeat request is started)
    attr_accessor :last_heartbeat_attempt_at

    HEARTBEAT_INTERVAL = 60 # seconds

    REMOTE_SETTING_KEYS = %w[
      enabled sample_rate memory_tracking_enabled allocation_tracking_enabled
      explain_analyze_enabled slow_query_threshold_ms max_sql_queries_to_send max_logs_to_send
      excluded_controllers excluded_jobs exclusive_controllers exclusive_jobs
      job_queue_monitoring_enabled enable_db_stats enable_process_stats enable_system_stats
    ].freeze

    def initialize
      @api_key = nil
      @open_timeout = 1.0
      @read_timeout = 1.0
      @enabled = true
      @ruby_dev = false
      @circuit_breaker_enabled = true
      @circuit_breaker_failure_threshold = 3
      @circuit_breaker_recovery_timeout = 60
      @circuit_breaker_retry_timeout = 300
      @deploy_id = resolve_deploy_id
      @disk_paths = ["/"]
      @interfaces_ignore = %w[lo lo0 docker0]

      # Remote-managed defaults (used until backend sends real values)
      @sample_rate = 100
      @memory_tracking_enabled = true
      @allocation_tracking_enabled = false
      @explain_analyze_enabled = false
      @slow_query_threshold_ms = 500
      @max_sql_queries_to_send = 500
      @max_logs_to_send = 100
      @excluded_controllers = []
      @excluded_jobs = []
      @exclusive_controllers = []
      @exclusive_jobs = []
      @job_queue_monitoring_enabled = false
      @enable_db_stats = false
      @enable_process_stats = false
      @enable_system_stats = false

      @settings_received_at = nil
      @last_heartbeat_at = nil
      @last_heartbeat_attempt_at = nil
      @settings_mutex = Mutex.new
    end

    # Apply a settings hash received from the backend response.
    # Only known keys are applied; unknown keys are silently ignored.
    # Serialized so concurrent HTTP threads do not interleave writes with request-thread reads.
    def apply_remote_settings(hash)
      return unless hash.is_a?(Hash)

      @settings_mutex.synchronize do
        hash.each do |key, value|
          k = key.to_s
          next unless REMOTE_SETTING_KEYS.include?(k)

          case k
          when "sample_rate", "slow_query_threshold_ms", "max_sql_queries_to_send", "max_logs_to_send"
            send(:"#{k}=", value.to_i)
          when "enabled", "memory_tracking_enabled", "allocation_tracking_enabled", "explain_analyze_enabled",
               "job_queue_monitoring_enabled", "enable_db_stats", "enable_process_stats", "enable_system_stats"
            send(:"#{k}=", !!value)
          when "excluded_controllers", "excluded_jobs", "exclusive_controllers", "exclusive_jobs"
            send(:"#{k}=", Array(value).map(&:to_s))
          end
        end
      end
    end

    def heartbeat_due?
      return false if api_key.nil?
      last_heartbeat_attempt_at.nil? || (Time.now.utc - last_heartbeat_attempt_at) >= HEARTBEAT_INTERVAL
    end

    def resolve_deploy_id
      ENV["dead_bro_DEPLOY_ID"] || ENV["GIT_REV"] || ENV["HEROKU_SLUG_COMMIT"] || DeadBro.process_deploy_id
    end

    def excluded_controller?(controller_name, action_name = nil)
      return false if @excluded_controllers.empty?

      # If action_name is provided, check both controller#action patterns and controller-only patterns
      if action_name
        target = "#{controller_name}##{action_name}"
        # Check controller#action patterns (patterns containing '#')
        action_patterns = @excluded_controllers.select { |pat| pat.to_s.include?("#") }
        if action_patterns.any? { |pat| match_name_or_pattern?(target, pat) }
          return true
        end
        # Check controller-only patterns (patterns without '#')
        # If the controller itself is excluded, all its actions are excluded
        controller_patterns = @excluded_controllers.reject { |pat| pat.to_s.include?("#") }
        if controller_patterns.any? { |pat| match_name_or_pattern?(controller_name, pat) }
          return true
        end
        return false
      end

      # When action_name is nil, only check controller-only patterns (no #)
      controller_patterns = @excluded_controllers.reject { |pat| pat.to_s.include?("#") }
      return false if controller_patterns.empty?
      controller_patterns.any? { |pat| match_name_or_pattern?(controller_name, pat) }
    end

    def excluded_job?(job_class_name)
      return false if @excluded_jobs.empty?
      @excluded_jobs.any? { |pat| match_name_or_pattern?(job_class_name, pat) }
    end

    def exclusive_job?(job_class_name)
      return true if @exclusive_jobs.empty? # If not defined, allow all (default behavior)
      @exclusive_jobs.any? { |pat| match_name_or_pattern?(job_class_name, pat) }
    end

    def exclusive_controller?(controller_name, action_name)
      return true if @exclusive_controllers.empty? # If not defined, allow all (default behavior)
      target = "#{controller_name}##{action_name}"
      @exclusive_controllers.any? { |pat| match_name_or_pattern?(target, pat) }
    end

    def should_sample?
      sample_rate = resolve_sample_rate
      sample_rate = 100 if sample_rate.nil?

      return true if sample_rate >= 100
      return false if sample_rate <= 0

      # Generate random number 1-100 and check if it's within sample rate
      rand(1..100) <= sample_rate
    end

    # Returns the configured sample_rate only (no ENV fallback). Use DeadBro.configure or remote settings.
    def resolve_sample_rate
      @sample_rate
    end

    def resolve_api_key
      return @api_key unless @api_key.nil?

      ENV["DEAD_BRO_API_KEY"]
    end

    private

    def match_name_or_pattern?(name, pattern)
      return false if name.nil? || pattern.nil?
      pat = pattern.to_s
      return !!(name.to_s == pat) unless pat.include?("*")

      # For controller action patterns (containing '#'), use .* to match any characters including colons
      # For controller-only patterns, use [^:]* to match namespace segments
      regex = if pat.include?("#")
        # Controller action pattern: allow * to match any characters including colons
        Regexp.new("^" + Regexp.escape(pat).gsub("\\*", ".*") + "$")
      else
        # Controller-only pattern: use [^:]* to match namespace segments
        Regexp.new("^" + Regexp.escape(pat).gsub("\\*", "[^:]*") + "$")
      end
      !!(name.to_s =~ regex)
    rescue
      false
    end
  end
end
