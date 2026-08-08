require "json"

module Chronicle
  # Strict event payload serialization contract (CONTRACT v0.5 #4): JSON only,
  # human-inspectable, byte-stable. Ported from activegraph.store.serde.
  #
  # Chronicle's Event payload is already a canonical JSON String, so the
  # encode-side strictness upstream implements (Decimal/datetime/set adapter)
  # is a compile-time guarantee of the type system here. This module is the
  # contract seam: decode-side corruption surfaces as CorruptedEventPayloadError,
  # and validate_event is the fail-fast emit-time gate (upstream
  # core/graph.py:emit).
  module Serde
    extend self

    # Encode a JSON value into a canonical JSON string.
    def encode_payload(payload : JSON::Any) : String
      payload.to_json
    end

    # Decode a stored payload string into JSON, or raise
    # CorruptedEventPayloadError with a preview of the offending bytes.
    def decode_payload(encoded : String) : JSON::Any
      JSON.parse(encoded)
    rescue error : JSON::ParseException
      preview = encoded.size <= 64 ? encoded : encoded[0, 60] + " ..."
      raise CorruptedEventPayloadError.new(
        "event payload could not be decoded as JSON (at column #{error.column_number}); " \
        "payload preview: #{preview.inspect}"
      )
    end

    # Fail-fast: ensure an event's payload round-trips through the strict
    # adapter before it is emitted (CONTRACT v0.5 #4).
    def validate_event(event : Event) : Nil
      encode_payload(decode_payload(event.payload))
      nil
    end

    # Row-ready envelope for store persistence (upstream store.serde.encode_event).
    # Payload stays a raw canonical JSON string so the row never re-parses it.
    struct StoredEvent
      include JSON::Serializable

      getter id : String
      getter type : String
      getter actor : String
      @[JSON::Field(converter: Chronicle::RawJSON)]
      getter payload : String
      getter frame_id : String?
      getter caused_by : String?
      getter timestamp : String
      getter schema_version : UInt16
      getter sequence : UInt64

      def initialize(
        @id : String,
        @type : String,
        @actor : String,
        @payload : String,
        @frame_id : String?,
        @caused_by : String?,
        @timestamp : String,
        @schema_version : UInt16,
        @sequence : UInt64,
      )
      end
    end

    # Map an Event to its row-ready envelope. Ported from
    # activegraph.store.serde.encode_event; schema_version/sequence are
    # Chronicle-specific envelope fields carried through the row.
    def encode_event(event : Event) : StoredEvent
      StoredEvent.new(
        id: event.id,
        type: event.type,
        actor: event.actor,
        payload: event.payload,
        frame_id: event.frame_id,
        caused_by: event.caused_by,
        timestamp: event.timestamp.to_rfc3339,
        schema_version: event.schema_version,
        sequence: event.sequence,
      )
    end

    # Rebuild an Event from a stored row. Ported from
    # activegraph.store.serde.decode_event.
    def decode_event(row : StoredEvent) : Event
      Event.new(
        schema_version: row.schema_version,
        sequence: row.sequence,
        id: row.id,
        type: row.type,
        actor: row.actor,
        caused_by: row.caused_by,
        frame_id: row.frame_id,
        timestamp: Time::Format::RFC_3339.parse(row.timestamp),
        payload: row.payload,
      )
    end
  end
end
