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

  describe ".safe_request_host" do
    Req = Struct.new(:host)

    it "reads request.host from the request object" do
      data = { request: Req.new("App.Example.COM") }
      expect(described_class.safe_request_host(data)).to eq("app.example.com")
    end

    it "falls back to HTTP_HOST from a headers hash and strips the port" do
      data = { headers: { "HTTP_HOST" => "shop.example.com:3000" } }
      expect(described_class.safe_request_host(data)).to eq("shop.example.com")
    end

    it "falls back to the env hash" do
      data = { env: { "HTTP_HOST" => "api.example.com" } }
      expect(described_class.safe_request_host(data)).to eq("api.example.com")
    end

    it "drops userinfo but keeps an IPv6 literal intact" do
      expect(described_class.safe_request_host({ request: Req.new("user@host.example.com") })).to eq("host.example.com")
      expect(described_class.safe_request_host({ headers: { "HTTP_HOST" => "[::1]:3000" } })).to eq("[::1]")
    end

    it "strips null bytes and returns empty string when absent" do
      expect(described_class.safe_request_host({ request: Req.new("ex\x00ample.com") })).to eq("example.com")
      expect(described_class.safe_request_host({})).to eq("")
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

    it "redacts sensitive keys" do
      data = { params: { "password" => "secret", "name" => "alice" } }
      result = described_class.safe_params(data)
      expect(result["password"]).to eq("[FILTERED]")
      expect(result["name"]).to eq("alice")
    end

    it "redacts sensitive keys nested at any level" do
      data = { params: { "user" => { "password" => "secret", "api_key" => "abc", "email" => "a@b.co" } } }
      result = described_class.safe_params(data)
      expect(result["user"]["password"]).to eq("[FILTERED]")
      expect(result["user"]["api_key"]).to eq("[FILTERED]")
      expect(result["user"]["email"]).to eq("a@b.co")
    end

    it "does not redact innocent keys that merely contain a sensitive substring" do
      data = { params: { "passenger_count" => 3, "cardinality" => 7 } }
      result = described_class.safe_params(data)
      expect(result["passenger_count"]).to eq(3)
      expect(result["cardinality"]).to eq(7)
    end
  end
end
