# frozen_string_literal: true

require "spec_helper"
require "dead_bro/profiling_middleware"

RSpec.describe DeadBro::ProfilingMiddleware do
  let(:downstream) { ->(_env) { [200, {}, ["ok"]] } }
  subject(:middleware) { described_class.new(downstream) }

  after { Thread.current[DeadBro::Profiler::MODE_KEY] = nil }

  it "passes the response through unchanged" do
    allow(DeadBro.configuration).to receive(:profile_active?).and_return(false)
    expect(middleware.call({})).to eq([200, {}, ["ok"]])
  end

  context "when profiling is active" do
    before do
      allow(DeadBro.configuration).to receive(:skip_tracking?).and_return(false)
      allow(DeadBro.configuration).to receive(:profile_active?).and_return(true)
      allow(DeadBro::Profiler).to receive(:pick_mode).and_return(:wall)
      allow(DeadBro::Profiler).to receive(:start).with(:wall).and_return(true)
    end

    it "starts the profiler and sets MODE_KEY for the subscriber to collect" do
      app = ->(_env) {
        # Mid-request: the subscriber would see the active mode here.
        expect(Thread.current[DeadBro::Profiler::MODE_KEY]).to eq(:wall)
        [200, {}, ["ok"]]
      }
      described_class.new(app).call({})
    end

    it "discards via safety net when the subscriber never collected (MODE_KEY still set)" do
      expect(DeadBro::Profiler).to receive(:discard)
      middleware.call({})
    end

    it "does not discard when the subscriber already collected (MODE_KEY cleared)" do
      app = ->(_env) {
        Thread.current[DeadBro::Profiler::MODE_KEY] = nil # simulate Subscriber#collect
        [200, {}, ["ok"]]
      }
      expect(DeadBro::Profiler).not_to receive(:discard)
      described_class.new(app).call({})
    end
  end

  it "does not start the profiler while skip_tracking? is true" do
    allow(DeadBro.configuration).to receive(:skip_tracking?).and_return(true)
    expect(DeadBro::Profiler).not_to receive(:start)
    middleware.call({})
  end
end
