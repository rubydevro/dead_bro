# frozen_string_literal: true

require "spec_helper"
require "active_support/parameter_filter"
require "rack/mock"
require "dead_bro/error_middleware"

RSpec.describe "Rails filter_parameters" do
  let(:filter_parameters) { [:phone, :content] }

  def stub_rails_filter_parameters(filters)
    config = double(filter_parameters: filters)
    stub_const("Rails", double(application: double(config: config)))
  end

  describe DeadBro::JobSubscriber, ".safe_arguments" do
    it "filters hash arguments with the app's filter_parameters" do
      stub_rails_filter_parameters(filter_parameters)

      arguments = described_class.safe_arguments([
        {connection_id: 1, sender_phone: "5511999999999", content: "private message"}
      ])

      expect(arguments.first).to eq(connection_id: 1, sender_phone: "[FILTERED]", content: "[FILTERED]")
    end

    it "keeps arguments as they were outside Rails" do
      arguments = described_class.safe_arguments([{sender_phone: "5511999999999"}])

      expect(arguments.first).to eq(sender_phone: "5511999999999")
    end
  end

  describe DeadBro::ErrorMiddleware do
    let(:captured_payloads) { [] }
    let(:client) do
      instance_double(DeadBro::Client).tap do |client|
        allow(client).to receive(:post_metric) { |**kwargs| captured_payloads << kwargs }
      end
    end
    let(:failing_app) { ->(_env) { raise "boom" } }

    def report_for(env)
      expect { described_class.new(failing_app, client).call(env) }.to raise_error("boom")
      captured_payloads.last[:payload][:rack]
    end

    it "filters params and the query string with the request's parameter filter" do
      env = Rack::MockRequest.env_for("/webhooks?phone=5511999999999&page=2",
        method: "POST", params: {content: "private message"})
      env["action_dispatch.parameter_filter"] = filter_parameters

      rack = report_for(env)

      expect(rack[:params]).to eq("phone" => "[FILTERED]", "page" => "2", "content" => "[FILTERED]")
      expect(rack[:fullpath]).to eq("/webhooks?phone=[FILTERED]&page=2")
    end

    it "falls back to the app's filter_parameters" do
      stub_rails_filter_parameters(filter_parameters)
      env = Rack::MockRequest.env_for("/webhooks?phone=5511999999999")

      rack = report_for(env)

      expect(rack[:params]).to eq("phone" => "[FILTERED]")
      expect(rack[:fullpath]).to eq("/webhooks?phone=[FILTERED]")
    end

    it "still redacts the gem's built-in sensitive keys without a filter" do
      env = Rack::MockRequest.env_for("/webhooks?api_key=secret&phone=5511999999999")

      rack = report_for(env)

      expect(rack[:params]).to eq("api_key" => "[FILTERED]", "phone" => "5511999999999")
      expect(rack[:fullpath]).to eq("/webhooks?api_key=secret&phone=5511999999999")
    end
  end
end
