# frozen_string_literal: true

module DeadBro
  class Configuration
    # Local-only settings (not overwritten by API `settings` payloads).
    # Note: `enabled` may still be updated remotely via apply_remote_settings when the backend
    # returns it in a response; local configure() values apply until the next remote update.
    attr_accessor :api_key, :open_timeout, :read_timeout, :enabled, :ruby_dev,
      :circuit_breaker_enabled, :circuit_breaker_failure_threshold, :circuit_breaker_recovery_timeout,
      :circuit_breaker_retry_timeout, :disk_paths, :interfaces_ignore

    # Remote-managed settings (overwritten by backend JSON `settings` on successful API responses)
    attr_accessor :memory_tracking_enabled, :allocation_tracking_enabled,
      :sample_rate, :slow_query_threshold_ms, :explain_analyze_enabled,
      :monitor_enabled, :enable_db_stats, :enable_process_stats, :enable_system_stats,
      :max_sql_queries_to_send, :max_logs_to_send

    # Readers for exclusion lists. Writers are defined below so we can compile
    # and cache the regex form once, instead of rebuilding it per request.
    attr_reader :excluded_controllers, :excluded_jobs, :exclusive_controllers, :exclusive_jobs

    # Tracks when we last received settings from the backend (in-memory only)
    attr_accessor :settings_received_at

    # After HTTP 507 Insufficient Storage from the API, skip all tracking until this
    # UTC time (in-memory only). Cleared on the next successful API response.
    attr_accessor :skip_until

    # Last successful heartbeat HTTP response time while disabled (in-memory only)
    attr_accessor :last_heartbeat_at

    # Throttles heartbeat attempts to HEARTBEAT_INTERVAL (set when a heartbeat request is started)
    attr_accessor :last_heartbeat_attempt_at

    HEARTBEAT_INTERVAL = 60 # seconds

    METRICS_BACKEND_SKIP_AFTER_507_SECONDS = 600 # 10 minutes

    # First non-empty ENV value wins for release/revision payloads and deploy grouping on the server.
    # Order is roughly: DeadBro-native → common CI/hosting → observability tooling.
    DEPLOY_REVISION_ENV_KEYS = %w[
      DEAD_BRO_DEPLOY_ID
      dead_bro_DEPLOY_ID
      GIT_REV
      GIT_COMMIT
      GIT_COMMIT_SHA
      GIT_SHA
      CODEBUILD_RESOLVED_SOURCE_REVISION
      HEROKU_SLUG_COMMIT
      RENDER_GIT_COMMIT
      DD_VERSION
      APP_REVISION
      RELEASE_VERSION
      SOURCE_VERSION
    ].freeze

    REMOTE_SETTING_KEYS = %w[
      enabled sample_rate memory_tracking_enabled allocation_tracking_enabled
      explain_analyze_enabled slow_query_threshold_ms max_sql_queries_to_send max_logs_to_send
      excluded_controllers excluded_jobs exclusive_controllers exclusive_jobs
      monitor_enabled enable_db_stats enable_process_stats enable_system_stats
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
      @explicit_deploy_revision = nil
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
      self.excluded_controllers = []
      self.excluded_jobs = []
      self.exclusive_controllers = []
      self.exclusive_jobs = []
      @monitor_enabled = false
      @enable_db_stats = false
      @enable_process_stats = false
      @enable_system_stats = false

      @settings_received_at = nil
      @skip_until = nil
      @last_heartbeat_at = nil
      @last_heartbeat_attempt_at = nil
      @settings_mutex = Mutex.new
    end

    # Current release revision sent as `revision` on all API payloads — same semantics as `#resolve_deploy_id`.
    def deploy_id
      resolve_deploy_id
    end

    # Overrides ENV-based resolution when set to a non-empty string (or clears override when nil/blank).
    def deploy_id=(value)
      s = value&.respond_to?(:to_s) ? value.to_s.strip : ""
      @explicit_deploy_revision = s.empty? ? nil : s
    end

    def excluded_controllers=(value)
      @excluded_controllers = Array(value).map(&:to_s)
      @compiled_excluded_controllers = compile_patterns(@excluded_controllers)
    end

    def excluded_jobs=(value)
      @excluded_jobs = Array(value).map(&:to_s)
      @compiled_excluded_jobs = compile_patterns(@excluded_jobs)
    end

    def exclusive_controllers=(value)
      @exclusive_controllers = Array(value).map(&:to_s)
      @compiled_exclusive_controllers = compile_patterns(@exclusive_controllers)
    end

    def exclusive_jobs=(value)
      @exclusive_jobs = Array(value).map(&:to_s)
      @compiled_exclusive_jobs = compile_patterns(@exclusive_jobs)
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
               "monitor_enabled", "enable_db_stats", "enable_process_stats", "enable_system_stats"
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

    def skip_tracking?
      t = skip_until
      return false unless t

      Time.now.utc < t
    end

    def resolve_deploy_id
      explicit = @explicit_deploy_revision&.to_s&.strip
      return explicit unless explicit.nil? || explicit.empty?

      DEPLOY_REVISION_ENV_KEYS.each do |key|
        v = ENV[key]
        next unless v.respond_to?(:to_s)

        stripped = v.to_s.strip
        next if stripped.empty?

        return stripped
      end

      DeadBro.process_deploy_id
    end

    def excluded_controller?(controller_name, action_name = nil)
      compiled = @compiled_excluded_controllers
      return false if compiled.nil? || compiled.empty?

      if action_name
        target = "#{controller_name}##{action_name}"
        compiled.each do |entry|
          if entry[:has_hash]
            return true if match_compiled?(target, entry)
          elsif match_compiled?(controller_name, entry)
            return true
          end
        end
        return false
      end

      compiled.each do |entry|
        next if entry[:has_hash]
        return true if match_compiled?(controller_name, entry)
      end
      false
    end

    def excluded_job?(job_class_name)
      compiled = @compiled_excluded_jobs
      return false if compiled.nil? || compiled.empty?
      compiled.any? { |entry| match_compiled?(job_class_name, entry) }
    end

    def exclusive_job?(job_class_name)
      compiled = @compiled_exclusive_jobs
      return true if compiled.nil? || compiled.empty?
      compiled.any? { |entry| match_compiled?(job_class_name, entry) }
    end

    def exclusive_controller?(controller_name, action_name)
      compiled = @compiled_exclusive_controllers
      return true if compiled.nil? || compiled.empty?
      target = "#{controller_name}##{action_name}"
      compiled.any? { |entry| match_compiled?(target, entry) }
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

    # Turn a list of user-facing patterns into {pattern, has_hash, regex}
    # entries. Regex is nil when the pattern is a plain literal (cheaper eq
    # compare). Compiling up-front removes per-request regex allocation.
    def compile_patterns(patterns)
      Array(patterns).map do |pat|
        s = pat.to_s
        has_hash = s.include?("#")
        regex = if s.include?("*")
          if has_hash
            Regexp.new("\\A" + Regexp.escape(s).gsub("\\*", ".*") + "\\z")
          else
            Regexp.new("\\A" + Regexp.escape(s).gsub("\\*", "[^:]*") + "\\z")
          end
        end
        {pattern: s, has_hash: has_hash, regex: regex}
      end
    rescue
      []
    end

    def match_compiled?(name, entry)
      return false if name.nil? || entry.nil?
      n = name.to_s
      if entry[:regex]
        !!(n =~ entry[:regex])
      else
        n == entry[:pattern]
      end
    rescue
      false
    end
  end
end
