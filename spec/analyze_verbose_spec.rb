# frozen_string_literal: true

require "spec_helper"

RSpec.describe "DeadBro.analyze verbose:" do
  before { allow($stdout).to receive(:puts) }

  describe "default (verbose: false)" do
    it "returns sql_queries without :trace key" do
      result = DeadBro.analyze("test") { nil }
      result[:sql_queries].each do |q|
        expect(q).not_to have_key(:trace)
      end
    end

    it "does not change Rails log level" do
      logger = double("logger", level: 2)
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
      stub_const("Rails", double(logger: logger, respond_to?: true))
      allow(Rails).to receive(:respond_to?).and_return(true)

      expect(logger).not_to receive(:level=)
      DeadBro.analyze("test") { nil }
    end

    it "does not enable ActiveRecord verbose_query_logs" do
      stub_const("ActiveRecord", Module.new)
      allow(ActiveRecord).to receive(:respond_to?).and_return(true)
      allow(ActiveRecord).to receive(:verbose_query_logs).and_return(false)

      expect(ActiveRecord).not_to receive(:verbose_query_logs=)
      DeadBro.analyze("test") { nil }
    end
  end

  describe "verbose: true" do
    it "lowers Rails log level to DEBUG during block and restores it after" do
      original_level = 2 # WARN
      logger = double("logger")
      allow(logger).to receive(:level).and_return(original_level)
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
      stub_const("Rails", double(respond_to?: true))
      allow(Rails).to receive(:respond_to?).and_return(true)
      allow(Rails).to receive(:logger).and_return(logger)

      expect(logger).to receive(:level=).with(0).ordered  # DEBUG = 0
      expect(logger).to receive(:level=).with(original_level).ordered

      DeadBro.analyze("test", verbose: true) { nil }
    end

    it "enables ActiveRecord verbose_query_logs during block and restores it after" do
      stub_const("ActiveRecord", Module.new)
      allow(ActiveRecord).to receive(:respond_to?).and_return(true)
      allow(ActiveRecord).to receive(:verbose_query_logs).and_return(false)

      expect(ActiveRecord).to receive(:verbose_query_logs=).with(true).ordered
      expect(ActiveRecord).to receive(:verbose_query_logs=).with(false).ordered

      DeadBro.analyze("test", verbose: true) { nil }
    end

    it "restores verbose_query_logs even when block raises" do
      stub_const("ActiveRecord", Module.new)
      allow(ActiveRecord).to receive(:respond_to?).and_return(true)
      allow(ActiveRecord).to receive(:verbose_query_logs).and_return(false)

      allow(ActiveRecord).to receive(:verbose_query_logs=)

      expect {
        DeadBro.analyze("test", verbose: true) { raise "boom" }
      }.to raise_error("boom")

      expect(ActiveRecord).to have_received(:verbose_query_logs=).with(false)
    end

    it "includes verbose: true in the returned result" do
      result = DeadBro.analyze("test", verbose: true) { nil }
      expect(result[:verbose]).to be true
    end

    it "does not add :trace key to sql_queries entries" do
      DeadBro::SqlSubscriber
      event_name = DeadBro::SqlSubscriber::SQL_EVENT_NAME

      result = DeadBro.analyze("test", verbose: true) do
        ActiveSupport::Notifications.instrument(event_name, sql: "SELECT 1", name: "User Load")
      end

      result[:sql_queries].each do |q|
        expect(q).not_to have_key(:trace)
      end
    end
  end
end
