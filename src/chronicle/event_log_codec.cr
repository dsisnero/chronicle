require "json"

module Chronicle
  # Pure, newline-delimited persistence format for immutable event logs.
  module EventLogCodec
    extend self

    FORMAT         = "chronicle.event-log"
    FORMAT_VERSION = 1

    # Typed decode view of the immutable event envelope.
    struct EventRecord
      include JSON::Serializable

      getter schema_version : UInt16
      getter sequence : UInt64
      getter id : String
      getter type : String
      getter actor : String
      getter caused_by : String?
      getter frame_id : String?
      getter timestamp : String
      @[JSON::Field(converter: Chronicle::RawJSON)]
      getter payload : String
    end

    def encode(log : EventLog) : String
      lines = [header]
      log.events.each { |event| lines << event.canonical_json }
      "#{lines.join("\n")}\n"
    end

    def decode(encoded : String) : EventLog
      lines = encoded.lines(chomp: true)
      validate_header!(lines.shift? || raise InvalidLogEncodingError.new("missing event log header"))
      events = lines.reject(&.empty?).map { |line| decode_event(line) }
      EventLog.from_events(events)
    rescue error : InvalidLogEncodingError
      raise error
    rescue error : EventSequenceError | DuplicateEventError | CausalParentError
      raise InvalidLogEncodingError.new("invalid event log: #{error.message}")
    end

    private def header : String
      %({"format":"#{FORMAT}","version":#{FORMAT_VERSION}})
    end

    private def validate_header!(line : String) : Nil
      value = JSON.parse(line).as_h
      format = value["format"]?.try(&.as_s)
      version = value["version"]?.try(&.as_i)
      raise InvalidLogEncodingError.new("invalid event log header") unless format == FORMAT && version
      raise InvalidLogEncodingError.new("unsupported event log format version") unless version == FORMAT_VERSION
    rescue JSON::ParseException | TypeCastError
      raise InvalidLogEncodingError.new("invalid event log header")
    end

    private def decode_event(line : String) : Event
      record = EventRecord.from_json(line)
      Event.new(
        schema_version: record.schema_version,
        sequence: record.sequence,
        id: record.id,
        type: record.type,
        actor: record.actor,
        caused_by: record.caused_by,
        frame_id: record.frame_id,
        timestamp: Time::Format::RFC_3339.parse(record.timestamp),
        payload: record.payload,
      )
    rescue JSON::ParseException | KeyError | TypeCastError | ArgumentError | OverflowError
      raise InvalidLogEncodingError.new("invalid event record")
    end
  end
end
