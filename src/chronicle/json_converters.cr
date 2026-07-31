require "json"

# Shared JSON converters for the deterministic core.
module Chronicle
  # Embeds/exposes an already-canonical JSON string as a raw JSON value, so
  # arbitrary data blobs (event payloads, object data) round-trip byte-exact.
  module RawJSON
    def self.from_json(pull : JSON::PullParser) : String
      JSON::Any.new(pull).to_json
    end

    def self.to_json(value : String, builder : JSON::Builder) : Nil
      builder.raw(value)
    end
  end
end
