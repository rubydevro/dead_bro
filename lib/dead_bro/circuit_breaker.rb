# frozen_string_literal: true

module DeadBro
  class CircuitBreaker
    # Circuit breaker states
    CLOSED = :closed
    OPEN = :open
    HALF_OPEN = :half_open

    # Default configuration
    DEFAULT_FAILURE_THRESHOLD = 3
    DEFAULT_RECOVERY_TIMEOUT = 60 # seconds
    DEFAULT_RETRY_TIMEOUT = 300 # seconds for retry attempts

    def initialize(
      failure_threshold: DEFAULT_FAILURE_THRESHOLD,
      recovery_timeout: DEFAULT_RECOVERY_TIMEOUT,
      retry_timeout: DEFAULT_RETRY_TIMEOUT
    )
      @failure_threshold = failure_threshold
      @recovery_timeout = recovery_timeout
      @retry_timeout = retry_timeout

      @state = CLOSED
      @failure_count = 0
      @last_failure_time = nil
      @last_success_time = nil
    end

    def call(&block)
      case @state
      when CLOSED
        execute_with_monitoring(&block)
      when OPEN
        if should_attempt_reset?
          @state = HALF_OPEN
          execute_with_monitoring(&block)
        else
          :circuit_open
        end
      when HALF_OPEN
        execute_with_monitoring(&block)
      end
    end

    attr_reader :state

    attr_reader :failure_count

    attr_reader :last_failure_time

    attr_reader :last_success_time

    def reset!
      @state = CLOSED
      @failure_count = 0
      @last_failure_time = nil
    end

    def open!
      @state = OPEN
      @last_failure_time = Time.now
    end

    def transition_to_half_open!
      @state = HALF_OPEN
    end

    def should_attempt_reset?
      return false unless @last_failure_time

      # Try to reset after recovery timeout
      elapsed = Time.now - @last_failure_time
      elapsed >= @recovery_timeout
    end

    private

    def execute_with_monitoring(&block)
      result = block.call

      if success?(result)
        on_success
        result
      else
        on_failure
        result
      end
    rescue => e
      on_failure
      raise e
    end

    def success?(result)
      # Consider 2xx status codes as success
      result.is_a?(Net::HTTPSuccess)
    end

    def on_success
      @failure_count = 0
      @last_success_time = Time.now
      @state = CLOSED
    end

    def on_failure
      @failure_count += 1
      @last_failure_time = Time.now

      # If we're in half-open state and get a failure, go back to open
      if @state == HALF_OPEN
        @state = OPEN
      elsif @failure_count >= @failure_threshold
        @state = OPEN
      end
    end
  end
end
