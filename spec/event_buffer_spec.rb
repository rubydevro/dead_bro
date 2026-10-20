# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::EventBuffer do
  let(:key) { :dead_bro_spec_events }

  after do
    Thread.current[key] = nil
    Thread.current[:"#{key}_spare"] = nil
  end

  it "hands a buffer with events to the caller and starts the next request with a new one" do
    described_class.start(key)
    Thread.current[key] << {event: "GET /rates"}
    events = described_class.stop(key)

    described_class.start(key)

    expect(events).to eq([{event: "GET /rates"}])
    expect(Thread.current[key]).not_to equal(events)
  end

  it "reuses a buffer that stayed empty, and reports no events" do
    described_class.start(key)
    buffer = Thread.current[key]

    expect(described_class.stop(key)).to equal(described_class::NONE)
    described_class.start(key)

    expect(Thread.current[key]).to equal(buffer)
  end

  it "stops tracking" do
    described_class.start(key)
    described_class.stop(key)

    expect(Thread.current[key]).to be_nil
    expect(described_class.stop(key)).to equal(described_class::NONE)
  end
end
