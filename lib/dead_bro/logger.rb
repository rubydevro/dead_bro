# frozen_string_literal: true

module DeadBro
  class Logger
    SEVERITY_LEVELS = {
      debug: 0,
      info: 1,
      warn: 2,
      error: 3,
      fatal: 4
    }.freeze

    # ANSI color codes
    COLOR_RESET = "\033[0m"
    COLOR_DEBUG = "\033[36m"  # Cyan
    COLOR_INFO = "\033[32m"   # Green
    COLOR_WARN = "\033[33m"   # Yellow
    COLOR_ERROR = "\033[31m" # Red
    COLOR_FATAL = "\033[35m"  # Magenta

    def initialize
      @thread_logs_key = :dead_bro_logs
    end

    def debug(message)
      log(:debug, message)
    end

    def info(message)
      log(:info, message)
    end

    def warn(message)
      log(:warn, message)
    end

    def error(message)
      log(:error, message)
    end

    def fatal(message)
      log(:fatal, message)
    end

    # Get all logs for the current thread
    def logs
      Thread.current[@thread_logs_key] || []
    end

    # Clear logs for the current thread
    def clear
      Thread.current[@thread_logs_key] = []
    end

    private

    def log(severity, message)
      timestamp = Time.now.utc
      log_entry = {
        sev: severity.to_s,
        msg: message.to_s,
        time: timestamp.iso8601(3) # Include milliseconds for better precision
      }

      # Store in thread-local storage
      Thread.current[@thread_logs_key] ||= []
      Thread.current[@thread_logs_key] << log_entry

      # Print the message immediately
      print_log(severity, message, timestamp)
    end

    def print_log(severity, message, timestamp)
      formatted_message = format_log_message(severity, message, timestamp)

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        # Use Rails logger if available (Rails handles its own color formatting)
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
        # Fallback to stdout with colors
        colored_message = format_log_message_with_color(severity, message, timestamp)
        $stdout.puts(colored_message)
      end
    rescue
      # Never let logging break the application
      $stdout.puts("[DeadBro] #{severity.to_s.upcase}: #{message}")
    end

    def format_log_message(severity, message, timestamp)
      "[DeadBro] #{timestamp.iso8601(3)} #{severity.to_s.upcase}: #{message}"
    end

    def format_log_message_with_color(severity, message, timestamp)
      color = color_for_severity(severity)
      severity_str = severity.to_s.upcase
      "#{color}[DeadBro] #{timestamp.iso8601(3)} #{severity_str}: #{message}#{COLOR_RESET}"
    end

    def color_for_severity(severity)
      case severity
      when :debug
        COLOR_DEBUG
      when :info
        COLOR_INFO
      when :warn
        COLOR_WARN
      when :error
        COLOR_ERROR
      when :fatal
        COLOR_FATAL
      else
        COLOR_RESET
      end
    end
  end
end
