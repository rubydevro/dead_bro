# frozen_string_literal: true

require_relative "dead_bro/version"

module DeadBro
  autoload :Configuration, "dead_bro/configuration"
  autoload :Client, "dead_bro/client"
  autoload :CircuitBreaker, "dead_bro/circuit_breaker"
  autoload :Subscriber, "dead_bro/subscriber"
  autoload :SqlSubscriber, "dead_bro/sql_subscriber"
  autoload :SqlTrackingMiddleware, "dead_bro/sql_tracking_middleware"
  autoload :CacheSubscriber, "dead_bro/cache_subscriber"
  autoload :RedisSubscriber, "dead_bro/redis_subscriber"
  autoload :ViewRenderingSubscriber, "dead_bro/view_rendering_subscriber"
  autoload :MemoryTrackingSubscriber, "dead_bro/memory_tracking_subscriber"
  autoload :MemoryLeakDetector, "dead_bro/memory_leak_detector"
  autoload :LightweightMemoryTracker, "dead_bro/lightweight_memory_tracker"
  autoload :MemoryHelpers, "dead_bro/memory_helpers"
  autoload :JobSubscriber, "dead_bro/job_subscriber"
  autoload :JobSqlTrackingMiddleware, "dead_bro/job_sql_tracking_middleware"
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
  end
end
