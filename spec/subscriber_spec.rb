# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeadBro::Subscriber do
  describe ".sanitize_string" do
    it "strips null bytes" do
      expect(described_class.sanitize_string("foo\x00bar")).to eq("foobar")
    end

    it "strips multiple null bytes" do
      expect(described_class.sanitize_string("\x00foo\x00bar\x00")).to eq("foobar")
    end

    it "leaves normal strings unchanged" do
      expect(described_class.sanitize_string("hello world")).to eq("hello world")
    end

    it "leaves other control characters unchanged" do
      expect(described_class.sanitize_string("line1\nline2\ttabbed")).to eq("line1\nline2\ttabbed")
    end

    it "converts nil to empty string" do
      expect(described_class.sanitize_string(nil)).to eq("")
    end

    it "converts non-string to string and strips null bytes" do
      expect(described_class.sanitize_string(:"foo\x00bar")).to eq("foobar")
    end
  end

  describe ".truncate_value" do
    it "strips null bytes from string values" do
      expect(described_class.truncate_value("foo\x00bar")).to eq("foobar")
    end

    it "strips null bytes recursively in hashes" do
      result = described_class.truncate_value({ page: "../../etc/passwd\x00.php" })
      expect(result[:page]).to eq("../../etc/passwd.php")
    end

    it "strips null bytes recursively in arrays" do
      result = described_class.truncate_value(["clean", "bad\x00value"])
      expect(result).to eq(["clean", "badvalue"])
    end

    it "truncates long strings" do
      long = "a" * 300
      result = described_class.truncate_value(long)
      expect(result.length).to be <= 205
      expect(result).to end_with("…")
    end

    it "passes through numeric values unchanged" do
      expect(described_class.truncate_value(42)).to eq(42)
      expect(described_class.truncate_value(3.14)).to eq(3.14)
    end

    it "passes through nil unchanged" do
      expect(described_class.truncate_value(nil)).to be_nil
    end
  end

  describe ".safe_path" do
    it "strips null bytes from path" do
      data = { path: "/videos?page=../../etc/passwd\x00.php" }
      expect(described_class.safe_path(data)).to eq("/videos?page=../../etc/passwd.php")
    end

    it "returns empty string on error" do
      expect(described_class.safe_path({})).to eq("")
    end
  end

  describe ".safe_params" do
    it "strips null bytes from param values" do
      data = { params: { "page" => "../../etc/passwd\x00.php" } }
      result = described_class.safe_params(data)
      expect(result["page"]).to eq("../../etc/passwd.php")
    end

    it "returns empty hash when params is nil" do
      expect(described_class.safe_params({})).to eq({})
    end

    it "filters sensitive keys" do
      data = { params: { "password" => "secret", "name" => "alice" } }
      result = described_class.safe_params(data)
      expect(result).not_to have_key("password")
      expect(result["name"]).to eq("alice")
    end
  end
end
