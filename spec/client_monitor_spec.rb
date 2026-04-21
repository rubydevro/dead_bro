# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Client, "#post_monitor_stats" do
  let(:config) do
    c = DeadBro::Configuration.new
    c.enabled = true
    c.api_key = "test_key"
    c.job_queue_monitoring_enabled = true
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

  it "skips request when job_queue_monitoring_enabled is false" do
    config.job_queue_monitoring_enabled = false
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
