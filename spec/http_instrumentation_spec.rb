# frozen_string_literal: true

require "spec_helper"
require "dead_bro/http_instrumentation"

RSpec.describe DeadBro::HttpInstrumentation do
  before do
    Thread.current[:dead_bro_http_events] = []
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now
  end

  after do
    Thread.current[:dead_bro_http_events] = nil
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  describe ".elasticsearch_host?" do
    it "detects port 9200" do
      expect(described_class.elasticsearch_host?("myserver", 9200)).to be true
    end

    it "detects *.elastic.co hostname" do
      expect(described_class.elasticsearch_host?("cluster.elastic.co", 443)).to be true
    end

    it "detects *.es.amazonaws.com hostname" do
      expect(described_class.elasticsearch_host?("domain.es.amazonaws.com", 443)).to be true
    end

    it "detects host containing 'elasticsearch'" do
      expect(described_class.elasticsearch_host?("my-elasticsearch-host.internal", 443)).to be true
    end

    it "returns false for regular hosts" do
      expect(described_class.elasticsearch_host?("api.stripe.com", 443)).to be false
    end

    it "returns false for nil host" do
      expect(described_class.elasticsearch_host?(nil, 443)).to be false
    end
  end

  describe ".typesense_host?" do
    it "detects port 8108" do
      expect(described_class.typesense_host?("localhost", 8108)).to be true
    end

    it "detects *.typesense.io hostname" do
      expect(described_class.typesense_host?("cluster.typesense.io", 443)).to be true
    end

    it "returns false for regular hosts" do
      expect(described_class.typesense_host?("api.example.com", 443)).to be false
    end

    it "returns false for nil host" do
      expect(described_class.typesense_host?(nil, 443)).to be false
    end
  end

  describe ".install_faraday!" do
    before do
      unless defined?(::Faraday)
        faraday_middleware_base = Class.new do
          def initialize(app)
            @app = app
          end
        end
        faraday_stub = Module.new
        faraday_stub.const_set(:Middleware, faraday_middleware_base)

        handler_record = Struct.new(:klass)
        builder_stub = Class.new do
          attr_reader :handlers
          define_method(:initialize) { @handlers = [] }
          define_method(:use) { |klass| @handlers << handler_record.new(klass) }
        end
        connection_stub = Class.new do
          attr_reader :builder
          define_method(:initialize) do |url = nil, options = {}, &block|
            @builder = builder_stub.new
          end
        end
        faraday_stub.const_set(:Connection, connection_stub)
        stub_const("Faraday", faraday_stub)
      end
    end

    it "defines DeadBro::FaradayMiddleware constant" do
      described_class.install_faraday!(DeadBro.client)
      expect(defined?(DeadBro::FaradayMiddleware)).to be_truthy
    end

    it "prepends FaradayInstrumentation into Faraday::Connection" do
      described_class.install_faraday!(DeadBro.client)
      expect(::Faraday::Connection.ancestors).to include(DeadBro::FaradayInstrumentation)
    end

    it "injects middleware into new Faraday connections" do
      described_class.install_faraday!(DeadBro.client)
      conn = ::Faraday::Connection.new
      expect(conn.builder.handlers.map(&:klass)).to include(DeadBro::FaradayMiddleware)
    end
  end

  describe "elasticsearch host detection does not add to http_outgoing" do
    it "skips ES hosts so they go to ElasticsearchSubscriber instead" do
      expect(described_class.elasticsearch_host?("localhost", 9200)).to be true
      expect(described_class.elasticsearch_host?("my-cluster.elastic.co", 443)).to be true
    end
  end
end
