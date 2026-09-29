# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe DeadBro::Sanitizer do
  describe ".string" do
    it "replaces bytes that aren't valid UTF-8 in a binary string, as Rack hands over headers" do
      result = described_class.string("iaskspider/2.0 \xA1".b)

      expect(result).to eq("iaskspider/2.0 �")
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(JSON.dump([result])).to eq("[\"iaskspider/2.0 �\"]")
    end

    it "replaces only the broken sequences of an invalid UTF-8 string" do
      expect(described_class.string("caf\xC3 ok".dup.force_encoding(Encoding::UTF_8))).to eq("caf� ok")
    end

    it "keeps valid multibyte UTF-8 that arrived as a binary string" do
      expect(described_class.string("café".b)).to eq("café")
    end

    it "transcodes other encodings instead of mangling them" do
      expect(described_class.string("caf\xE9".dup.force_encoding(Encoding::ISO_8859_1))).to eq("café")
      expect(described_class.string("héllo".encode(Encoding::UTF_16LE))).to eq("héllo")
    end

    it "falls back to replacing bytes when there's no converter for the encoding" do
      result = described_class.string("abc\xFF".dup.force_encoding(Encoding::UTF_7))

      expect(result).to eq("abc�")
      expect(result).to be_valid_encoding
    end

    it "strips NUL bytes" do
      expect(described_class.string("foo\u0000bar")).to eq("foobar")
      expect(described_class.string("bad\xA1\u0000".b)).to eq("bad�")
    end

    it "returns a clean string as is, without allocating a copy" do
      clean = +"Mozilla/5.0 (Macintosh) café"
      ascii_binary = "Mozilla/5.0".b

      expect(described_class.string(clean)).to equal(clean)
      expect(described_class.string(ascii_binary)).to equal(ascii_binary)
    end

    it "converts non-strings with to_s" do
      expect(described_class.string(nil)).to eq("")
      expect(described_class.string(:html)).to eq("html")
      expect(described_class.string(42)).to eq("42")
    end
  end

  describe ".deep" do
    it "scrubs every string in nested hashes and arrays, keys included" do
      value = {
        "ua" => "bot \xA1".b,
        "k\xFF".b => ["ok", "b\xFE".b, 1, 2.5, nil, true],
        nested: {list: [{deep: "x\u0000y"}]}
      }

      expect(described_class.deep(value)).to eq(
        "ua" => "bot �",
        "k�" => ["ok", "b�", 1, 2.5, nil, true],
        nested: {list: [{deep: "xy"}]}
      )
    end

    it "keeps symbol keys, which the client looks payload fields up by" do
      expect(described_class.deep({logs: [{msg: "a"}]}).keys).to eq([:logs])
    end

    it "does not modify the original structure" do
      original = {ua: "bot \xA1".b}

      described_class.deep(original)

      expect(original[:ua]).to eq("bot \xA1".b)
    end

    it "leaves objects it doesn't know alone" do
      time = Time.now

      expect(described_class.deep({at: time})[:at]).to equal(time)
    end
  end
end
