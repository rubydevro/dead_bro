# frozen_string_literal: true

require "spec_helper"
require "dead_bro/view_rendering_subscriber"

RSpec.describe DeadBro::ViewRenderingSubscriber do
  before do
    described_class.subscribe!
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = Time.now
  end

  after do
    described_class.take_aggregates
    ActiveSupport::Notifications.unsubscribe(described_class::RENDER_TEMPLATE_EVENT)
    ActiveSupport::Notifications.unsubscribe(described_class::RENDER_PARTIAL_EVENT)
    ActiveSupport::Notifications.unsubscribe(described_class::RENDER_COLLECTION_EVENT)
    Thread.current[DeadBro::TRACKING_START_TIME_KEY] = nil
  end

  def render(event, identifier, **payload)
    ActiveSupport::Notifications.instrument(event, identifier: identifier, **payload) {}
  end

  it "aggregates renders per template, most rendered first" do
    described_class.start_request_tracking
    render(described_class::RENDER_TEMPLATE_EVENT, "/srv/app/views/shipments/show.html.erb")
    3.times { render(described_class::RENDER_PARTIAL_EVENT, "/srv/app/views/shipments/_stop.html.erb", cache_key: "stop/1") }
    render(described_class::RENDER_COLLECTION_EVENT, "/srv/app/views/shipments/_parcel.html.erb", count: 12, cached_count: 4)

    views = described_class.stop_request_tracking

    expect(views.map { |v| v[:identifier] }.first).to eq("views/shipments/_stop.html.erb")
    expect(views.first).to include(type: "partial", count: 3, cache_hit_count: 3)
    expect(views.find { |v| v[:type] == "collection" }).to include(collection_count: 12, collection_cached_count: 4)
    expect(views.find { |v| v[:type] == "template" }[:rendered_at_min]).to be_a(Integer)
  end

  it "sets nothing up until the first render" do
    described_class.start_request_tracking

    expect(Thread.current[described_class::THREAD_LOCAL_AGGREGATES_KEY]).to be_nil
    expect(described_class.stop_request_tracking).to eq([])
  end

  it "hands the aggregates over unsorted, for the dispatcher to sort" do
    described_class.start_request_tracking
    render(described_class::RENDER_TEMPLATE_EVENT, "/srv/app/views/shipments/show.html.erb")
    2.times { render(described_class::RENDER_PARTIAL_EVENT, "/srv/app/views/shipments/_stop.html.erb") }

    aggregates = described_class.take_aggregates

    expect(aggregates).to be_a(Hash)
    expect(Thread.current[described_class::THREAD_LOCAL_AGGREGATES_KEY]).to be_nil
    expect(described_class.sort_aggregates(aggregates).map { |v| v[:count] }).to eq([2, 1])
  end

  it "ignores renders outside a tracked request" do
    render(described_class::RENDER_TEMPLATE_EVENT, "/srv/app/views/shipments/show.html.erb")

    expect(Thread.current[described_class::THREAD_LOCAL_AGGREGATES_KEY]).to be_nil
  end
end
