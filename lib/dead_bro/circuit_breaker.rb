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
      @mutex = Mutex.new
    end

    def call(&block)
      state = @mutex.synchronize { @state }
      case state
      when CLOSED
        execute_with_monitoring(&block)
      when OPEN
        if should_attempt_reset?
          @mutex.synchronize { @state = HALF_OPEN }
          execute_with_monitoring(&block)
        else
          :circuit_open
        end
      when HALF_OPEN
        execute_with_monitoring(&block)
      end
    end

    def state
      @mutex.synchronize { @state }
    end

    def failure_count
      @mutex.synchronize { @failure_count }
    end

    def last_failure_time
      @mutex.synchronize { @last_failure_time }
    end

    def last_success_time
      @mutex.synchronize { @last_success_time }
    end

    def reset!
      @mutex.synchronize do
        @state = CLOSED
        @failure_count = 0
        @last_failure_time = nil
      end
    end

    def open!
      @mutex.synchronize do
        @state = OPEN
        @last_failure_time = Time.now
      end
    end

    def transition_to_half_open!
      @mutex.synchronize { @state = HALF_OPEN }
    end

    def should_attempt_reset?
      @mutex.synchronize do
        return false unless @last_failure_time
        (Time.now - @last_failure_time) >= @recovery_timeout
      end
    end

    # Public entry points for callers that already know the outcome (e.g. the
    # HTTP dispatcher thread). Preferred over `call(&block)` when the caller
    # is doing its own error handling.
    def record_success
      @mutex.synchronize do
        @failure_count = 0
        @last_success_time = Time.now
        @state = CLOSED
      end
    end

    def record_failure
      @mutex.synchronize do
        @failure_count += 1
        @last_failure_time = Time.now
        if @state == HALF_OPEN || @failure_count >= @failure_threshold
          @state = OPEN
        end
      end
    end

    private

    # Historical names kept as private aliases so existing specs and any
    # internal callers that reach in via `send(:on_success)` still work.
    alias_method :on_success, :record_success
    alias_method :on_failure, :record_failure

    def execute_with_monitoring(&block)
      result = block.call

      if success?(result)
        record_success
        result
      else
        record_failure
        result
      end
    rescue => e
      record_failure
      raise e
    end

    def success?(result)
      result.is_a?(Net::HTTPSuccess)
    end
  end
end
