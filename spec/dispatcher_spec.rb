# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Dispatcher do
  around do |example|
    DeadBro::Dispatcher.inline = false
    example.run
  ensure
    DeadBro::Dispatcher.inline = true
  end

  let(:dispatcher) { described_class.new(queue_size: 10, workers: 1) }

  after { dispatcher.shutdown }

  def wait_for(queue)
    Timeout.timeout(2) { queue.pop }
  end

  it "runs a block on a worker thread" do
    ran_on = Queue.new
    dispatcher.dispatch { ran_on << Thread.current }

    expect(wait_for(ran_on)).not_to eq(Thread.current)
  end

  it "runs any object that responds to #call, so callers needn't allocate a block" do
    ran = Queue.new
    job = Object.new
    job.define_singleton_method(:call) { ran << :ran }

    expect(dispatcher.dispatch(job)).to be true
    expect(wait_for(ran)).to eq(:ran)
  end

  it "refuses to schedule nothing" do
    expect(dispatcher.dispatch).to be false
  end
end
