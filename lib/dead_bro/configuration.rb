# frozen_string_literal: true

module DeadBro
  class Configuration
    attr_accessor :api_key, :open_timeout, :read_timeout, :enabled, :ruby_dev, :memory_tracking_enabled, 
    :allocation_tracking_enabled, :circuit_breaker_enabled, :circuit_breaker_failure_threshold, :circuit_breaker_recovery_timeout, 
    :circuit_breaker_retry_timeout, :sample_rate, :excluded_controllers, :excluded_jobs,
    :exclusive_controllers, :exclusive_jobs, :deploy_id, :slow_query_threshold_ms, :explain_analyze_enabled

    def initialize
      @api_key = nil
      @endpoint_url = nil
      @open_timeout = 1.0
      @read_timeout = 1.0
      @enabled = true
      @ruby_dev = false
      @memory_tracking_enabled = true
      @allocation_tracking_enabled = false # Disabled by default for performance
      @circuit_breaker_enabled = true
      @circuit_breaker_failure_threshold = 3
      @circuit_breaker_recovery_timeout = 60 # seconds
      @circuit_breaker_retry_timeout = 300 # seconds
      @sample_rate = 100
      @excluded_controllers = []
      @excluded_jobs = []
      @exclusive_controllers = []
      @exclusive_jobs = []
      @deploy_id = resolve_deploy_id
      @slow_query_threshold_ms = 500 # Default: 500ms
      @explain_analyze_enabled = false # Enable EXPLAIN ANALYZE for slow queries by default
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
      return true if sample_rate >= 100
      return false if sample_rate <= 0

      # Generate random number 1-100 and check if it's within sample rate
      rand(1..100) <= sample_rate
    end
    
    def resolve_sample_rate
      return @sample_rate unless @sample_rate.nil?
      
      if ENV["dead_bro_SAMPLE_RATE"]
        env_value = ENV["dead_bro_SAMPLE_RATE"].to_s.strip
        # Validate that it's a valid integer string
        if env_value.match?(/^\d+$/)
          parsed = env_value.to_i
          # Ensure it's in valid range (0-100)
          (parsed >= 0 && parsed <= 100) ? parsed : 100
        else
          100 # Invalid format, fall back to default
        end
      else
        100 # default
      end
    end
    
    def resolve_api_key
      return @api_key unless @api_key.nil?
      
      ENV["DEAD_BRO_API_KEY"]
    end

    def sample_rate=(value)
      # Allow nil to use default/resolved value
      return @sample_rate = nil if value.nil?

      # Allow 0 to disable sampling, or 1-100 for percentage
      unless value.is_a?(Integer) && value >= 0 && value <= 100
        raise ArgumentError, "Sample rate must be an integer between 0 and 100, got: #{value.inspect}"
      end
      @sample_rate = value
    end

    private

    def match_name_or_pattern?(name, pattern)
      return false if name.nil? || pattern.nil?
      pat = pattern.to_s
      return !!(name.to_s == pat) unless pat.include?("*")
      
      # For controller action patterns (containing '#'), use .* to match any characters including colons
      # For controller-only patterns, use [^:]* to match namespace segments
      if pat.include?("#")
        # Controller action pattern: allow * to match any characters including colons
        regex = Regexp.new("^" + Regexp.escape(pat).gsub("\\*", ".*") + "$")
      else
        # Controller-only pattern: use [^:]* to match namespace segments
        regex = Regexp.new("^" + Regexp.escape(pat).gsub("\\*", "[^:]*") + "$")
      end
      !!(name.to_s =~ regex)
    rescue
      false
    end

  end
end
