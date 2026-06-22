# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Configuration, "#profile_active?" do
  subject(:config) { described_class.new }

  before { allow(DeadBro::Profiler).to receive(:available?).and_return(true) }

  it "defaults to off (profile_enabled false, sample_rate 0)" do
    expect(config.profile_enabled).to be(false)
    expect(config.profile_sample_rate).to eq(0)
    expect(config.profile_active?).to be(false)
  end

  it "is false when enabled but stackprof is unavailable" do
    allow(DeadBro::Profiler).to receive(:available?).and_return(false)
    config.profile_enabled = true
    config.profile_sample_rate = 100
    expect(config.profile_active?).to be(false)
  end

  it "is true when enabled, available, and sample_rate is 100" do
    config.profile_enabled = true
    config.profile_sample_rate = 100
    expect(config.profile_active?).to be(true)
  end

  it "is false when sample_rate is 0 even if enabled" do
    config.profile_enabled = true
    config.profile_sample_rate = 0
    expect(config.profile_active?).to be(false)
  end

  it "samples within the configured rate" do
    config.profile_enabled = true
    config.profile_sample_rate = 50
    allow(config).to receive(:rand).with(1..100).and_return(40, 60)
    expect(config.profile_active?).to be(true)
    expect(config.profile_active?).to be(false)
  end

  describe "remote settings round-trip" do
    it "applies profile keys with correct coercion" do
      config.apply_remote_settings(
        "profile_enabled" => true,
        "profile_sample_rate" => "7",
        "profile_max_bytes" => "500000"
      )
      expect(config.profile_enabled).to be(true)
      expect(config.profile_sample_rate).to eq(7)
      expect(config.profile_max_bytes).to eq(500_000)
    end
  end
end
