#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"

module DeadBro
  module Collectors
    # SampleStore provides a tiny, best-effort persistence layer for
    # time-series samples (CPU, network, etc.) between runs.
    #
    # It prefers Redis via Sidekiq when available and otherwise falls back
    # to a JSON file in /tmp. All failures are swallowed and simply result
    # in nil being returned from #load.
    module SampleStore
      module_function

      def load(key)
        load_from_redis(key) || load_from_file(key)
      rescue
        nil
      end

      def save(key, data)
        save_to_redis(key, data)
      rescue
        # If Redis is unavailable or fails, fall back to file-based storage
      ensure
        begin
          save_to_file(key, data)
        rescue
          # Completely best-effort
        end
      end

      def load_from_redis(key)
        return nil unless defined?(Sidekiq) && Sidekiq.respond_to?(:redis)

        raw = Sidekiq.redis { |r| r.get(redis_key(key)) }
        return nil unless raw

        JSON.parse(raw)
      rescue
        nil
      end

      def save_to_redis(key, data)
        return unless defined?(Sidekiq) && Sidekiq.respond_to?(:redis)

        Sidekiq.redis do |r|
          r.set(redis_key(key), JSON.dump(data), ex: 300) # keep for 5 minutes
        end
      rescue
        # Best-effort only
      end

      def load_from_file(key)
        path = file_path(key)
        return nil unless File.file?(path)

        File.open(path, "r") do |f|
          JSON.parse(f.read)
        end
      rescue
        nil
      end

      def save_to_file(key, data)
        path = file_path(key)
        dir = File.dirname(path)
        Dir.mkdir(dir) unless Dir.exist?(dir)

        File.open(path, File::RDWR | File::CREAT, 0o600) do |f|
          f.flock(File::LOCK_EX)
          f.rewind
          f.truncate(0)
          f.write(JSON.dump(data))
        ensure
          begin
            f.flock(File::LOCK_UN)
          rescue
          end
        end
      rescue
        # Best-effort only
      end

      def redis_key(key)
        env = DeadBro.env
        host = begin
          require "socket"
          Socket.gethostname
        rescue
          "unknown"
        end

        "dead_bro:metrics:#{env}:#{host}:#{key}"
      end

      def file_path(key)
        digest = Digest::SHA256.hexdigest(key.to_s)[0, 16]
        File.join(Dir.tmpdir, "dead_bro_metrics_#{digest}.json")
      rescue
        "/tmp/dead_bro_metrics_#{key.to_s.gsub(/[^a-zA-Z0-9]/, "_")}.json"
      end
    end
  end
end
