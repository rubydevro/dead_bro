#!/usr/bin/env ruby
# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe DeadBro::Collectors::ProcessInfo do
  describe ".parse_proc_status_for_rss" do
    it "parses VmRSS from a /proc/self/status-like file" do
      content = <<~STATUS
        Name:\tmyprocess
        State:\tR (running)
        VmRSS:\t  12345 kB
        Threads:\t10
      STATUS

      Tempfile.create("proc_status") do |file|
        file.write(content)
        file.flush

        rss = described_class.parse_proc_status_for_rss(file.path)
        expect(rss).to eq(12345 * 1024)
      end
    end
  end
  describe "on MacOS" do
    before do
      allow(described_class).to receive(:linux?).and_return(false)
      allow(described_class).to receive(:macos?).and_return(true)
    end

    describe ".fd_count" do
      it "counts entries in /dev/fd" do
        allow(File).to receive(:directory?).with("/dev/fd").and_return(true)
        # Mock Dir.entries to return ".", "..", "0", "1", "2" (5 entries -> 3 FDs)
        allow(Dir).to receive(:entries).with("/dev/fd").and_return([".", "..", "0", "1", "2"])

        expect(described_class.fd_count).to eq(3)
      end

      it "returns nil if /dev/fd is missing" do
        allow(File).to receive(:directory?).with("/dev/fd").and_return(false)
        expect(described_class.fd_count).to be_nil
      end
    end

    describe ".rss_bytes" do
      it "uses ps command" do
        # Mock ps output: "1024" (kb)
        allow(described_class).to receive(:`).with(/ps -o rss=/).and_return("  1024\n")

        expect(described_class.rss_bytes).to eq(1024 * 1024)
      end
    end
  end
end
