# frozen_string_literal: true

require "spec_helper"
require "dead_bro/ar_object_tracker"

RSpec.describe DeadBro::ArObjectTracker do
  after { Thread.current[described_class::THREAD_KEY] = nil }

  describe ".start_request_tracking / .stop_request_tracking" do
    it "returns nil when stop called without start" do
      expect(described_class.stop_request_tracking).to be_nil
    end

    it "returns 0 with no events after start/stop" do
      described_class.start_request_tracking
      expect(described_class.stop_request_tracking).to eq(0)
    end

    it "clears the thread key after stop" do
      described_class.start_request_tracking
      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end

    it "clears the thread key even when stop is called without start" do
      described_class.stop_request_tracking
      expect(Thread.current[described_class::THREAD_KEY]).to be_nil
    end
  end

  describe "notification accumulation" do
    before(:context) { described_class.subscribe! }

    it "accumulates record_count from instantiation.active_record events" do
      described_class.start_request_tracking

      ActiveSupport::Notifications.instrument("instantiation.active_record", record_count: 5)
      ActiveSupport::Notifications.instrument("instantiation.active_record", record_count: 3)

      expect(described_class.stop_request_tracking).to eq(8)
    end

    it "defaults to 1 when record_count is absent" do
      described_class.start_request_tracking

      ActiveSupport::Notifications.instrument("instantiation.active_record", {})

      expect(described_class.stop_request_tracking).to eq(1)
    end

    it "ignores events fired outside of a tracked request" do
      ActiveSupport::Notifications.instrument("instantiation.active_record", record_count: 10)

      described_class.start_request_tracking
      ActiveSupport::Notifications.instrument("instantiation.active_record", record_count: 2)

      expect(described_class.stop_request_tracking).to eq(2)
    end

    it "does not accumulate after stop" do
      described_class.start_request_tracking
      ActiveSupport::Notifications.instrument("instantiation.active_record", record_count: 4)
      described_class.stop_request_tracking

      # fire after stop — should not raise or affect anything
      expect {
        ActiveSupport::Notifications.instrument("instantiation.active_record", record_count: 99)
      }.not_to raise_error
    end

    it "does not install a second listener when subscribe! is called again" do
      # @subscribed is already true from before(:context); a second call must be a no-op
      expect(ActiveSupport::Notifications).not_to receive(:subscribe)
      described_class.subscribe!
    end
  end
end
