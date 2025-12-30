# frozen_string_literal: true

begin
  require "rails/railtie"
rescue LoadError
  # Rails not available, skip railtie definition
end

# Only define Railtie if Rails is available
if defined?(Rails) && defined?(Rails::Railtie)
  module DeadBro
    class Railtie < ::Rails::Railtie

      initializer "dead_bro.subscribe" do |app|
        app.config.after_initialize do
          # Use the shared Client instance for all subscribers
          shared_client = DeadBro.client
          
          DeadBro::Subscriber.subscribe!(client: shared_client)
          # Install outgoing HTTP instrumentation
          require "dead_bro/http_instrumentation"
          DeadBro::HttpInstrumentation.install!(client: shared_client)

          # Install SQL query tracking
          require "dead_bro/sql_subscriber"
          DeadBro::SqlSubscriber.subscribe!

          # Install Rails cache tracking
          require "dead_bro/cache_subscriber"
          DeadBro::CacheSubscriber.subscribe!

          # Install Redis tracking (if Redis-related events are present)
          require "dead_bro/redis_subscriber"
          DeadBro::RedisSubscriber.subscribe!

          # Install view rendering tracking
          require "dead_bro/view_rendering_subscriber"
          DeadBro::ViewRenderingSubscriber.subscribe!(client: shared_client)

          # Install lightweight memory tracking (default)
          require "dead_bro/lightweight_memory_tracker"
          require "dead_bro/memory_leak_detector"
          DeadBro::MemoryLeakDetector.initialize_history

          # Install detailed memory tracking only if enabled
          if DeadBro.configuration.allocation_tracking_enabled
            require "dead_bro/memory_tracking_subscriber"
            DeadBro::MemoryTrackingSubscriber.subscribe!(client: shared_client)
          end

          # Install job tracking if ActiveJob is available
          if defined?(ActiveJob)
            require "dead_bro/job_subscriber"
            require "dead_bro/job_sql_tracking_middleware"
            DeadBro::JobSqlTrackingMiddleware.subscribe!
            DeadBro::JobSubscriber.subscribe!(client: shared_client)
          end
        rescue
          # Never raise in Railtie init
        end
      end

      # Insert Rack middleware early enough to observe uncaught exceptions
      initializer "dead_bro.middleware" do |app|
        require "dead_bro/error_middleware"
        
        # Use the shared Client instance for the middleware
        shared_client = DeadBro.client

        if defined?(::ActionDispatch::DebugExceptions)
          app.config.middleware.insert_before(::ActionDispatch::DebugExceptions, ::DeadBro::ErrorMiddleware, shared_client)
        elsif defined?(::ActionDispatch::ShowExceptions)
          app.config.middleware.insert_before(::ActionDispatch::ShowExceptions, ::DeadBro::ErrorMiddleware, shared_client)
        else
          app.config.middleware.use(::DeadBro::ErrorMiddleware, shared_client)
        end
      rescue
        # Never raise in Railtie init
      end

      # Insert SQL tracking middleware
      initializer "dead_bro.sql_tracking_middleware" do |app|
        require "dead_bro/sql_tracking_middleware"
        app.config.middleware.use(::DeadBro::SqlTrackingMiddleware)
      rescue
        # Never raise in Railtie init
      end
    end
  end
end
