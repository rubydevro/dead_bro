# frozen_string_literal: true

RSpec.describe DeadBro::DependencyInventory do
  let(:config) { DeadBro::Configuration.new }

  describe ".build" do
    it "returns the documented payload shape" do
      h = described_class.build(configuration: config)

      expect(h[:schema_version]).to eq(1)
      expect(h[:collected_at]).to match(/\d{4}-\d{2}-\d{2}T/)
      expect(h[:app]).to include(:name, :environment)
      expect(h[:deploy]).to include(:revision, :hostname, :instance_id, :pid)
      expect(h[:runtime]).to include(:ruby_version, :ruby_platform, :rails_version, :bundler_version)
      expect(h).to have_key(:lockfile_sha256)
      expect(h[:collection_source]).to be_a(String)
      expect(%w[bundler_definition_specs gem_loaded_specs]).to include(h[:collection_source])
      expect(h[:gem_count]).to eq(h[:gems].size)
      expect(h[:gems]).to be_an(Array)
      expect(h[:gems]).not_to be_empty
      first = h[:gems].first
      expect(first).to include(:name, :version)
    end

    it "optionally includes dependency_groups when enabled" do
      config.inventory_include_gem_groups = true
      h = described_class.build(configuration: config)
      expect(h).to have_key(:dependency_groups)
      expect(h[:dependency_groups]).to be_a(Hash) if h[:dependency_groups]
    end

    it "sets app name when inventory_app_name is configured" do
      config.inventory_app_name = "my-app"
      h = described_class.build(configuration: config)
      expect(h.dig(:app, :name)).to eq("my-app")
    end

    it "uses inventory_instance_id when set" do
      config.inventory_instance_id = "i-12345"
      h = described_class.build(configuration: config)
      expect(h.dig(:deploy, :instance_id)).to eq("i-12345")
    end
  end
end

RSpec.describe DeadBro::InventoryHeartbeat do
  before do
    described_class.reset!
    DeadBro.reset_configuration!
    @client = instance_double(DeadBro::Client)
    allow(DeadBro).to receive(:client).and_return(@client)
  end

  after do
    described_class.reset!
    DeadBro.reset_configuration!
  end

  it "does nothing when dependency_inventory_enabled is false" do
    DeadBro.configure do |c|
      c.api_key = "secret"
      c.enabled = true
      c.dependency_inventory_enabled = false
    end

    expect(@client).not_to receive(:post_dependency_inventory)
    described_class.start
  end

  it "posts once when enabled and api key present" do
    DeadBro.configure do |c|
      c.api_key = "secret"
      c.enabled = true
      c.dependency_inventory_enabled = true
      c.dependency_inventory_heartbeat_interval_seconds = 0
    end

    expect(@client).to receive(:post_dependency_inventory).once.with(hash_including(:gems, :runtime))

    described_class.start
  end
end

RSpec.describe DeadBro::Client do
  describe "#post_dependency_inventory" do
    let(:config) { DeadBro::Configuration.new }
    let(:client) { DeadBro::Client.new(config) }

    before do
      config.enabled = true
      config.api_key = "test_key"
    end

    it "POSTs to the inventory endpoint in ruby_dev mode" do
      config.ruby_dev = true
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "localhost", port: 3100, scheme: "http", request_uri: "/apm/v1/inventory")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      ok = double("HTTPSuccess")
      allow(ok).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request).and_return(ok)

      expect(URI).to receive(:parse).with("http://localhost:3100/apm/v1/inventory")
      client.post_dependency_inventory({gems: []})
    end

    it "skips when api key is missing (including ENV fallback empty)" do
      config.api_key = nil
      ENV.delete("DEAD_BRO_API_KEY")

      expect_any_instance_of(Net::HTTP).not_to receive(:request)
      client.post_dependency_inventory({})
    end

    it "uses DEAD_BRO_API_KEY when api_key is unset" do
      config.api_key = nil
      ENV["DEAD_BRO_API_KEY"] = "from-env"
      config.ruby_dev = true
      http_double = double("Net::HTTP")
      uri_double = double("URI", host: "localhost", port: 3100, scheme: "http", request_uri: "/apm/v1/inventory")
      allow(URI).to receive(:parse).and_return(uri_double)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:use_ssl=)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      ok = double("HTTPSuccess")
      allow(ok).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double).to receive(:request) do |req|
        expect(req["Authorization"]).to eq("Bearer from-env")
        ok
      end

      client.post_dependency_inventory({test: 1})
      ENV.delete("DEAD_BRO_API_KEY")
    end
  end
end
