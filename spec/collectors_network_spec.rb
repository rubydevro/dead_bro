# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Collectors::Network do
  describe ".collect" do
    let(:now) { 1000.0 }

    before do
      DeadBro.reset_configuration!
      allow(described_class).to receive(:current_time).and_return(now)
      allow(DeadBro::Collectors::SampleStore).to receive(:load).and_return(nil)
      allow(DeadBro::Collectors::SampleStore).to receive(:save)
    end

    context "on Linux" do
      before do
        allow(described_class).to receive(:linux?).and_return(true)
        allow(described_class).to receive(:macos?).and_return(false)
        allow(File).to receive(:readable?).with("/proc/net/dev").and_return(true)
      end

      it "parses /proc/net/dev correctly" do
        proc_net_dev = <<~Output
          Inter-|   Receive                                                |  Transmit
           face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
             lo: 123456       1    0    0    0     0          0         0   654321       1    0    0    0     0       0          0
           eth0: 1000000     10    0    0    0     0          0         0  2000000      20    0    0    0     0       0          0
        Output

        # Mocking File.foreach block
        lines = proc_net_dev.split("\n")
        # lines[2] is lo, lines[3] is eth0
        
        # We need to mock File.foreach to yield these lines
        allow(File).to receive(:foreach).with("/proc/net/dev").and_yield(lines[2]).and_yield(lines[3])

        result = described_class.collect

        expect(result[:available]).to be true
        eth0 = result[:interfaces].find { |i| i[:name] == "eth0" }
        expect(eth0).to include(rx_bytes: 1000000, tx_bytes: 2000000)
        
        # lo is ignored by default
        lo = result[:interfaces].find { |i| i[:name] == "lo" }
        expect(lo).to be_nil
      end

      it "returns only the top interface by activity" do
        proc_net_dev = <<~Output
          Inter-|   Receive                                                |  Transmit
           face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
           eth0: 1000        1    0    0    0     0          0         0     500       1    0    0    0     0       0          0
           eth1: 1000000     10    0    0    0     0          0         0  2000000      20    0    0    0     0       0          0
        Output

        # eth1 has more traffic than eth0
        allow(File).to receive(:foreach).with("/proc/net/dev").and_yield(proc_net_dev.split("\n")[2]).and_yield(proc_net_dev.split("\n")[3])

        result = described_class.collect

        expect(result[:interfaces].size).to eq(1)
        expect(result[:interfaces].first[:name]).to eq("eth1")
      end
    end

    context "on MacOS" do
      before do
        allow(described_class).to receive(:linux?).and_return(false)
        allow(described_class).to receive(:macos?).and_return(true)
      end

      it "parses netstat -ib correctly" do
        netstat_output = <<~Output
          Name  Mtu   Network       Address            Ipkts Ierrs    Ibytes    Opkts Oerrs     Obytes  Coll
          lo0   16384 <Link#1>                        309756     0  49057632   309756     0   49057632     0
          en0   1500  <Link#4>    88:66:5a:00:22:11  2685232     0 3123456789  1501234     0 234567890     0
          utun0 1380  <Link#14>                          0     0         0        0     0          0     0
        Output

        allow(described_class).to receive(:`).with("netstat -ib").and_return(netstat_output)

        result = described_class.collect

        expect(result[:available]).to be true
        
        en0 = result[:interfaces].find { |i| i[:name] == "en0" }
        expect(en0[:rx_bytes]).to eq(3123456789)
        expect(en0[:tx_bytes]).to eq(234567890)
        
        # lo0 ignored
        lo0 = result[:interfaces].find { |i| i[:name] == "lo0" }
        expect(lo0).to be_nil
      end

      it "parses lines without address correctly" do
        # Simulating a case where address is missing but data is valid
        netstat_output = <<~Output
          Name  Mtu   Network       Address            Ipkts Ierrs    Ibytes    Opkts Oerrs     Obytes  Coll
          p2p0  2304  <Link#10>                       123     0    10240      123     0     20480     0
        Output
        
        allow(described_class).to receive(:`).with("netstat -ib").and_return(netstat_output)

        result = described_class.collect
        p2p0 = result[:interfaces].find { |i| i[:name] == "p2p0" }
        expect(p2p0[:rx_bytes]).to eq(10240)
        expect(p2p0[:tx_bytes]).to eq(20480)
      end
    end

    context "on unknown OS" do
      before do
        allow(described_class).to receive(:linux?).and_return(false)
        allow(described_class).to receive(:macos?).and_return(false)
      end

      it "returns available: false" do
        expect(described_class.collect).to eq(available: false)
      end
    end
  end
end
