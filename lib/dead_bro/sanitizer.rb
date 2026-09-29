# frozen_string_literal: true

module DeadBro
  # Makes values safe to JSON-encode and to store on the backend: every String
  # comes out as valid UTF-8 without NUL bytes.
  #
  # Rack hands header values over as binary strings holding whatever bytes the
  # client sent, and JSON.dump raises on any that aren't valid UTF-8 — a bot's
  # user agent carrying a stray "\xA1" was enough to turn a host app's 200 into
  # a 500. NUL bytes are valid JSON, but PostgreSQL rejects them in text columns.
  module Sanitizer
    REPLACEMENT = "�"
    NUL = "\u0000"

    module_function

    # Returns value.to_s as valid UTF-8 without NUL bytes. A string that is
    # already clean is returned as is, so the common case allocates nothing.
    def string(value)
      str = value.to_s
      str = to_utf8(str) unless str.ascii_only? || (str.encoding == Encoding::UTF_8 && str.valid_encoding?)
      str.include?(NUL) ? str.delete(NUL) : str
    end

    # Copies Hashes and Arrays, running every String (keys included) through
    # .string. Anything else is returned untouched — Symbols too, since they come
    # from code rather than from clients, and payload code looks keys up by Symbol.
    def deep(value)
      case value
      when String
        string(value)
      when Hash
        value.each_with_object({}) { |(k, v), out| out[deep(k)] = deep(v) }
      when Array
        value.map { |v| deep(v) }
      else
        value
      end
    end

    def to_utf8(str)
      case str.encoding
      when Encoding::BINARY, Encoding::US_ASCII, Encoding::UTF_8
        # Raw bytes of unknown origin, or a broken UTF-8 string: read the bytes
        # as UTF-8 and replace only the sequences that aren't.
        utf8 = str.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : utf8.scrub(REPLACEMENT)
      else
        str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
      end
    rescue EncodingError
      # No converter from this encoding — keep whatever reads as UTF-8.
      str.dup.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT)
    end
  end
end
