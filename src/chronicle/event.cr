require "json"

module Chronicle
  # An immutable input to the log projection, supplied by the platform edge.
  struct Event
    getter schema_version : UInt16
    getter sequence : UInt64
    getter id : String
    getter type : String
    getter actor : String
    getter caused_by : String?
    getter frame_id : String?
    getter timestamp : Time
    getter payload : String

    def initialize(
      @schema_version : UInt16,
      @sequence : UInt64,
      @id : String,
      @type : String,
      @actor : String,
      @caused_by : String?,
      @payload : String,
      @frame_id : String? = nil,
      @timestamp : Time = Time.utc,
    )
      begin
        JSON.parse(@payload)
      rescue JSON::ParseException
        raise InvalidEventError.new("payload must be valid JSON")
      end
    end

    # Produces the byte-stable envelope used for log persistence and hashing.
    # Payload is supplied as already-canonical JSON by the platform edge.
    def canonical_json : String
      JSON.build do |json|
        json.object do
          json.field "schema_version", schema_version
          json.field "sequence", sequence
          json.field "id", id
          json.field "type", type
          json.field "actor", actor
          json.field "caused_by", caused_by
          json.field "frame_id", frame_id
          json.field "timestamp", timestamp.to_rfc3339
          json.field "payload" do
            json.raw(payload)
          end
        end
      end
    end

    # SHA-256 digest of the exact canonical envelope bytes.
    def content_hash : String
      ContentHash.digest(canonical_json)
    end
  end
end
