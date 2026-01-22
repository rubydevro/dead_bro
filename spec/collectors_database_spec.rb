# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Collectors::Database do
  describe ".collect" do
    before do
      DeadBro.reset_configuration!
      allow(DeadBro.configuration).to receive(:enable_db_stats).and_return(true)
    end

      it "returns available: false" do
        hide_const("ActiveRecord")
        expect(described_class.collect).to eq(available: false)
      end

    context "when ActiveRecord is defined" do
      let(:ar_base) { Class.new }
      let(:connection_pool) { double("ConnectionPool", size: 5, connections: [], busy: 0, dead: 0, num_waiting: 0, automatic_reconnect: true) }

      before do
        stub_const("ActiveRecord::Base", ar_base)
        allow(ar_base).to receive(:respond_to?).with(:connection_pool).and_return(true)
        allow(ar_base).to receive(:connection_pool).and_return(connection_pool)
      end

      it "returns available: true and stats when pool exists" do
        # Mock ping
        allow(described_class).to receive(:ping_ms).and_return(1.23)
        allow(connection_pool).to receive(:connections).and_return(double(size: 2))

        result = described_class.collect

        expect(result[:available]).to be true
        expect(result[:pool][:size]).to eq(5)
        expect(result[:ping_ms]).to eq(1.23)
      end

      it "uses with_connection for ping" do
        allow(described_class).to receive(:current_time).and_return(1000.0, 1000.1)
        
        connection = double("Connection", adapter_name: "PostgreSQL")
        expect(connection).to receive(:select_value).with("SELECT 1")
        
        expect(connection_pool).to receive(:with_connection).and_yield(connection)
        
        described_class.ping_ms(ar_base)
      end
    end
  end
end
