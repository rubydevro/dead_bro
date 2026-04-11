# frozen_string_literal: true

require "digest"
require "socket"

module DeadBro
  # Builds a dependency snapshot for the heartbeat/inventory API (DED-162).
  #
  # Gem list strategy (documented):
  # - When Bundler is available: use +Bundler.definition.specs+ (resolved versions for the
  #   current definition) and +Gemfile.lock+ SHA-256 for diff-friendly lockfile identity.
  # - Otherwise: fall back to +Gem.loaded_specs+ (actually loaded gems only).
  class DependencyInventory
    SCHEMA_VERSION = 1

    def self.build(configuration: DeadBro.configuration)
      new(configuration).to_h
    end

    def initialize(configuration)
      @configuration = configuration
    end

    def to_h
      gems, lockfile_sha256, collection_source = collect_gems_and_lockfile

      payload = {
        schema_version: SCHEMA_VERSION,
        collected_at: Time.now.utc.iso8601,
        app: {
          name: resolve_app_name,
          environment: DeadBro.env.to_s
        },
        deploy: {
          revision: @configuration.resolve_deploy_id,
          hostname: resolve_hostname,
          instance_id: resolve_instance_id,
          pid: Process.pid
        },
        runtime: {
          ruby_version: RUBY_VERSION,
          ruby_platform: RUBY_PLATFORM,
          rails_version: resolve_rails_version,
          bundler_version: resolve_bundler_version
        },
        lockfile_sha256: lockfile_sha256,
        gem_count: gems.size,
        gems: gems,
        collection_source: collection_source
      }

      groups = dependency_groups_if_enabled
      payload[:dependency_groups] = groups if groups

      payload
    end

    private

    def collect_gems_and_lockfile
      if bundler_usable?
        begin
          specs = Bundler.definition.specs.to_a.sort_by(&:name)
          gems = specs.map { |s| {name: s.name, version: s.version.to_s} }
          return [gems, lockfile_digest, "bundler_definition_specs"]
        rescue StandardError
          # Fall through to loaded specs
        end
      end

      gems = Gem.loaded_specs.values.sort_by(&:name).map { |s|
        {name: s.name, version: s.version.to_s}
      }
      [gems, nil, "gem_loaded_specs"]
    end

    def bundler_usable?
      defined?(Bundler) && Bundler.respond_to?(:definition)
    end

    def lockfile_digest
      return nil unless bundler_usable?
      path = Bundler.default_lockfile
      return nil unless path && File.readable?(path)

      Digest::SHA256.hexdigest(File.read(path))
    rescue StandardError
      nil
    end

    def resolve_app_name
      name = @configuration.inventory_app_name
      return name if name && !name.to_s.empty?

      if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        begin
          mod = Rails.application.class.module_parent_name
          return mod if mod && !mod.to_s.empty?
        rescue StandardError
        end
      end

      nil
    end

    def resolve_hostname
      Socket.gethostname
    rescue StandardError
      nil
    end

    def resolve_instance_id
      id = @configuration.inventory_instance_id
      return id if id && !id.to_s.empty?

      host = resolve_hostname
      host ? "#{host}-#{Process.pid}" : "pid-#{Process.pid}"
    end

    def resolve_rails_version
      return nil unless defined?(Rails)

      Rails.version
    rescue StandardError
      nil
    end

    def resolve_bundler_version
      return nil unless defined?(Bundler)

      Bundler::VERSION
    rescue StandardError
      nil
    end

    def dependency_groups_if_enabled
      return nil unless @configuration.inventory_include_gem_groups
      return nil unless bundler_usable?

      out = {}
      Bundler.definition.dependencies.each do |dep|
        dep.groups.each do |g|
          (out[dep.name] ||= []) << g.to_s
        end
      end
      out.transform_values! { |groups| groups.uniq.sort }
      out
    rescue StandardError
      nil
    end
  end
end
