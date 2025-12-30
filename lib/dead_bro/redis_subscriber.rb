# frozen_string_literal: true

module DeadBro
  class RedisSubscriber
    THREAD_LOCAL_KEY = :dead_bro_redis_events

    def self.subscribe!
      install_redis_instrumentation!
    rescue
      # Never raise from instrumentation install
    end

    def self.install_redis_instrumentation!
      # Only instrument Redis::Client - this is where commands actually execute
      # Don't instrument Redis class as it has public methods with different signatures
      if defined?(::Redis::Client)
        install_redis_client!
      end

      # Also try ActiveSupport::Notifications if events are available
      install_notifications_subscription!
    end

    def self.install_redis_client!
      # Only instrument if Redis::Client actually has the call method
      # Check both public and private methods
      has_call = ::Redis::Client.instance_methods(false).include?(:call) ||
        ::Redis::Client.private_instance_methods(false).include?(:call)
      return unless has_call

      mod = Module.new do
        # Use method_missing alternative or alias_method pattern
        # We'll use prepend but make the method signature as flexible as possible
        def call(*args, &block)
          # Extract command from args - first arg is typically the command array
          command = args.first
          # Only track if thread-local storage is set up
          if Thread.current[RedisSubscriber::THREAD_LOCAL_KEY] && !command.nil?
            record_redis_command(command) do
              super(*args, &block)
            end
          else
            # If not tracking, just pass through unchanged
            super
          end
        end

        def call_pipeline(pipeline)
          record_redis_pipeline(pipeline) do
            super
          end
        end

        def call_multi(multi)
          record_redis_multi(multi) do
            super
          end
        end

        private

        def record_redis_command(command)
          return yield unless Thread.current[RedisSubscriber::THREAD_LOCAL_KEY]

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          error = nil
          begin
            result = yield
            result
          rescue Exception => e
            error = e
            raise
          ensure
            finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finish_time - start_time) * 1000.0).round(2)

            begin
              cmd_info = extract_command_info(command)
              event = {
                event: "redis.command",
                command: cmd_info[:command],
                key: cmd_info[:key],
                args_count: cmd_info[:args_count],
                duration_ms: duration_ms,
                db: safe_db(@db),
                error: error ? error.class.name : nil
              }

              if Thread.current[RedisSubscriber::THREAD_LOCAL_KEY]
                Thread.current[RedisSubscriber::THREAD_LOCAL_KEY] << event
              end
            rescue
            end
          end
        end

        def record_redis_pipeline(pipeline)
          return yield unless Thread.current[RedisSubscriber::THREAD_LOCAL_KEY]

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            result = yield
            result
          ensure
            finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finish_time - start_time) * 1000.0).round(2)

            begin
              commands_count = pipeline.commands&.length || 0
              event = {
                event: "redis.pipeline",
                commands_count: commands_count,
                duration_ms: duration_ms,
                db: safe_db(@db)
              }

              if Thread.current[RedisSubscriber::THREAD_LOCAL_KEY]
                Thread.current[RedisSubscriber::THREAD_LOCAL_KEY] << event
              end
            rescue
            end
          end
        end

        def record_redis_multi(multi)
          return yield unless Thread.current[RedisSubscriber::THREAD_LOCAL_KEY]

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            result = yield
            result
          ensure
            finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_ms = ((finish_time - start_time) * 1000.0).round(2)

            begin
              commands_count = multi.commands&.length || 0
              event = {
                event: "redis.multi",
                commands_count: commands_count,
                duration_ms: duration_ms,
                db: safe_db(@db)
              }

              if Thread.current[RedisSubscriber::THREAD_LOCAL_KEY]
                Thread.current[RedisSubscriber::THREAD_LOCAL_KEY] << event
              end
            rescue
            end
          end
        end

        def extract_command_info(command)
          parts = Array(command).map(&:to_s)
          command_name = parts.first&.upcase
          key = parts[1]
          args_count = (parts.length > 1) ? parts.length - 1 : 0

          {
            command: safe_command(command_name),
            key: safe_key(key),
            args_count: args_count
          }
        rescue
          {command: nil, key: nil, args_count: nil}
        end

        def safe_command(cmd)
          return nil if cmd.nil?
          cmd.to_s[0, 20]
        rescue
          nil
        end

        def safe_key(key)
          return nil if key.nil?
          s = key.to_s
          (s.length > 200) ? s[0, 200] + "…" : s
        rescue
          nil
        end

        def safe_db(db)
          Integer(db)
        rescue
          nil
        end
      end

      ::Redis::Client.prepend(mod) unless ::Redis::Client.ancestors.include?(mod)
    rescue
      # Redis::Client may not be available or may have different structure
    end

    def self.install_notifications_subscription!
      # Try to subscribe to ActiveSupport::Notifications if available
      # This covers cases where other libraries emit redis.* events
      if defined?(ActiveSupport::Notifications)
        begin
          ActiveSupport::Notifications.subscribe(/\Aredis\..+\z/) do |name, started, finished, _unique_id, data|
            next unless Thread.current[THREAD_LOCAL_KEY]
            duration_ms = ((finished - started) * 1000.0).round(2)
            event = build_event(name, data, duration_ms)
            Thread.current[THREAD_LOCAL_KEY] << event if event
          end
        rescue
        end
      end
    end

    def self.start_request_tracking
      Thread.current[THREAD_LOCAL_KEY] = []
    end

    def self.stop_request_tracking
      events = Thread.current[THREAD_LOCAL_KEY]
      Thread.current[THREAD_LOCAL_KEY] = nil
      events || []
    end

    def self.build_event(name, data, duration_ms)
      cmd = extract_command(data)
      {
        event: name.to_s,
        command: cmd[:command],
        key: cmd[:key],
        args_count: cmd[:args_count],
        duration_ms: duration_ms,
        db: safe_db(data[:db])
      }
    rescue
      nil
    end

    def self.extract_command(data)
      return {command: nil, key: nil, args_count: nil} unless data.is_a?(Hash)

      parts = if data[:command]
        Array(data[:command]).map(&:to_s)
      elsif data[:commands]
        Array(data[:commands]).flatten.map(&:to_s)
      elsif data[:cmd]
        Array(data[:cmd]).map(&:to_s)
      else
        []
      end

      command_name = parts.first&.upcase
      key = parts[1]
      args_count = parts.length - 1 if parts.any?

      {
        command: safe_command(command_name),
        key: safe_key(key),
        args_count: args_count
      }
    rescue
      {command: nil, key: nil, args_count: nil}
    end

    def self.safe_command(cmd)
      return nil if cmd.nil?
      cmd.to_s[0, 20]
    rescue
      nil
    end

    def self.safe_key(key)
      return nil if key.nil?
      s = key.to_s
      (s.length > 200) ? s[0, 200] + "…" : s
    rescue
      nil
    end

    def self.safe_db(db)
      Integer(db)
    rescue
      nil
    end
  end
end
