# frozen_string_literal: true

module DeadBro
  # Sends dependency inventory to the DeadBro backend after boot and on an optional interval.
  class InventoryHeartbeat
    @mutex = Mutex.new
    @started = false

    class << self
      # For tests: allow multiple starts in the same process.
      def reset!
        @mutex.synchronize { @started = false }
      end

      def start
        cfg = DeadBro.configuration
        return unless cfg.dependency_inventory_enabled
        return unless cfg.enabled

        key = cfg.api_key || cfg.resolve_api_key
        return if key.nil? || key.to_s.empty?

        @mutex.synchronize do
          return if @started
          @started = true
        end

        client = DeadBro.client
        post = lambda {
          payload = DeadBro::DependencyInventory.build(configuration: cfg)
          client.post_dependency_inventory(payload)
        }

        begin
          post.call
        rescue StandardError
        end

        interval = cfg.dependency_inventory_heartbeat_interval_seconds.to_i
        return if interval <= 0

        Thread.new do
          loop do
            sleep interval
            begin
              post.call
            rescue StandardError
            end
          end
        end
      rescue StandardError
        # Never raise from boot hook
      end
    end
  end
end
