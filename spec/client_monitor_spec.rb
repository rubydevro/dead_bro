# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Client, "#post_monitor_stats" do
  let(:config) do
    c = DeadBro::Configuration.new
    c.enabled = true
    c.api_key = "test_key"
    c.monitor_enabled = true
    c
  end

  let(:client) { described_class.new(config) }

  def stub_http(response: nil)
    response ||= instance_double(Net::HTTPSuccess, body: "{}")
    allow(response).to receive(:is_a?) { |k| k == Net::HTTPSuccess }

    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)

    allow(Net::HTTP).to receive(:new).and_return(http)
    http
  end

  it "skips request when api_key is nil" do
    config.api_key = nil
    expect(Net::HTTP).not_to receive(:new)
    client.post_monitor_stats({jobs: []})
  end

  it "skips request when disabled" do
    config.enabled = false
    expect(Net::HTTP).not_to receive(:new)
    client.post_monitor_stats({jobs: []})
  end

  it "skips request when skip_tracking? is active" do
    config.skip_until = Time.now.utc + 3600
    expect(Net::HTTP).not_to receive(:new)
    client.post_monitor_stats({jobs: []})
  end

  it "skips request when monitor_enabled is false" do
    config.monitor_enabled = false
    expect(Net::HTTP).not_to receive(:new)
    client.post_monitor_stats({jobs: []})
  end

  it "dispatches an HTTP request" do
    http = stub_http
    expect(http).to receive(:request)
    client.post_monitor_stats({jobs: []})
  end

  it "uses ruby_dev endpoint when enabled" do
    config.ruby_dev = true
    client = described_class.new(config)

    captured_host = nil
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(instance_double(Net::HTTPSuccess, body: "{}", is_a?: true))
    allow(Net::HTTP).to receive(:new) { |host, port| captured_host = host; http }

    client.post_monitor_stats({jobs: []})

    expect(captured_host).to eq("localhost")
  end

  it "skips request when circuit breaker is open and not ready to reset" do
    config.circuit_breaker_enabled = true
    client = described_class.new(config)
    client.instance_variable_get(:@circuit_breaker).open!

    expect(Net::HTTP).not_to receive(:new)
    client.post_monitor_stats({jobs: []})
  end

  it "records circuit breaker failure on HTTP error" do
    config.circuit_breaker_enabled = true
    client = described_class.new(config)
    cb = client.instance_variable_get(:@circuit_breaker)

    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_raise(StandardError, "network error")
    allow(Net::HTTP).to receive(:new).and_return(http)

    expect { client.post_monitor_stats({jobs: []}) }.not_to raise_error
    expect(cb.failure_count).to eq(1)
  end

  it "records circuit breaker success on 2xx response" do
    config.circuit_breaker_enabled = true
    client = described_class.new(config)
    cb = client.instance_variable_get(:@circuit_breaker)
    # Seed one failure so we can verify it resets
    cb.record_failure

    stub_http
    client.post_monitor_stats({jobs: []})

    expect(cb.failure_count).to eq(0)
    expect(cb.state).to eq(:closed)
  end
end

# The monitor asks before collecting: collecting queries the job backend and
# the database, which is wasted when post_monitor_stats would drop the result.
RSpec.describe DeadBro::Client, "#monitor_stats_wanted?" do
  let(:config) do
    DeadBro::Configuration.new.tap do |c|
      c.api_key = "test_key"
      c.monitor_enabled = true
    end
  end

  let(:client) { described_class.new(config) }

  it "is true with an API key and the monitor on" do
    expect(client.monitor_stats_wanted?).to be(true)
  end

  it "is false without an API key" do
    config.api_key = nil

    expect(client.monitor_stats_wanted?).to be(false)
  end

  it "is false until the app's settings turn the monitor on" do
    config.monitor_enabled = DeadBro::Configuration.new.monitor_enabled

    expect(client.monitor_stats_wanted?).to be(false)
  end

  it "is false when disabled" do
    config.enabled = false

    expect(client.monitor_stats_wanted?).to be(false)
  end

  it "is false while tracking is skipped after a 507" do
    config.skip_until = Time.now.utc + 600

    expect(client.monitor_stats_wanted?).to be(false)
  end
end
