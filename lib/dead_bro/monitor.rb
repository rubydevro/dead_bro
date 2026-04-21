# frozen_string_literal: true

module DeadBro
  class Monitor
    SLEEP_INTERVAL_SECONDS = 60

    def initialize(client: DeadBro.client)
      @client = client
      @thread = nil
      @running = false
      @stop_mutex = Mutex.new
      @stop_cv = ConditionVariable.new
    end

    def start
      # Live thread already running — nothing to do.
      return if @running && @thread&.alive?

      # Reset: handles post-fork where @running=true but the thread is dead.
      @running = false

      return unless DeadBro.configuration.enabled

      @running = true
      @thread = Thread.new do
        Thread.current.abort_on_exception = false
        loop do
          break unless @running

          begin
            collect_and_send_stats
          rescue => e
            log_error("Error collecting stats: #{e.message}")
          end

          # Interruptible sleep — stop() signals the CV so shutdown doesn't
          # block up to a full minute. Still naps the full interval during
          # normal operation.
          @stop_mutex.synchronize do
            @stop_cv.wait(@stop_mutex, SLEEP_INTERVAL_SECONDS) if @running
          end
        end
      end

      @thread
    end

    def stop
      @running = false
      @stop_mutex.synchronize { @stop_cv.broadcast }
      @thread&.join(5) # Safety timeout in case the thread is mid-flight
      @thread = nil
    end

    private

    def collect_and_send_stats
      payload = {
        environment: DeadBro.env,
        host: process_hostname,
        pid: Process.pid,
        current_time: Time.now.utc.iso8601,
        jobs: DeadBro::Collectors::Jobs.collect,
        network: DeadBro::Collectors::Network.collect
      }

      if DeadBro.configuration.respond_to?(:enable_db_stats) && DeadBro.configuration.enable_db_stats
        payload[:db] = safe_collect { DeadBro::Collectors::Database.collect }
      end

      if DeadBro.configuration.respond_to?(:enable_process_stats) && DeadBro.configuration.enable_process_stats
        payload[:process] = safe_collect { DeadBro::Collectors::ProcessInfo.collect }
      end

      if DeadBro.configuration.respond_to?(:enable_system_stats) && DeadBro.configuration.enable_system_stats
        payload[:system] = safe_collect { DeadBro::Collectors::System.collect }
      end
      @client.post_monitor_stats(payload)
    end

    def process_hostname
      require "socket"
      Socket.gethostname
    rescue
      "unknown"
    end

    def log_error(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error("[DeadBro::Monitor] #{message}")
      else
        $stderr.puts("[DeadBro::Monitor] #{message}")
      end
    end

    def safe_collect
      yield
    rescue => e
      {error_class: e.class.name, error_message: e.message.to_s[0, 500]}
    end
  end
end
