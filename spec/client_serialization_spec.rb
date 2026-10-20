# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe DeadBro::Client, "serializing payloads" do
  let(:config) do
    DeadBro::Configuration.new.tap do |c|
      c.enabled = true
      c.api_key = "test_key"
      c.sample_rate = 100
    end
  end
  let(:client) { described_class.new(config) }
  let(:bodies) { [] }

  before do
    http = double("Net::HTTP", "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil)
    allow(http).to receive(:request) do |request|
      bodies << request.body
      nil
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  it "sends a payload with a string that isn't valid UTF-8 by retrying with every string scrubbed" do
    client.post_metric(event_name: "test", payload: {logs: [{msg: "cache miss for key \xA1".b}]})

    expect(bodies.size).to eq(1)
    expect(JSON.parse(bodies.first)["payload"]["logs"]).to eq([{"msg" => "cache miss for key �"}])
    expect(client.serialization_failures).to eq(0)
  end

  it "drops and counts a payload that fails to serialize for another reason, without raising" do
    unserializable = Object.new
    def unserializable.to_json(*)
      raise NoMethodError, "undefined method for #<Tempfile>"
    end

    expect { client.post_metric(event_name: "test", payload: {upload: unserializable}) }.not_to raise_error

    expect(bodies).to be_empty
    expect(client.serialization_failures).to eq(1)
  end

  it "drops and counts a payload that still can't be encoded after scrubbing, without raising" do
    # Symbols are left alone by the scrub (they come from code), so one built
    # from raw bytes still fails the retry.
    expect { client.post_metric(event_name: "test", payload: {state: "bad\xA1".b.to_sym}) }.not_to raise_error

    expect(bodies).to be_empty
    expect(client.serialization_failures).to eq(1)
  end
end
