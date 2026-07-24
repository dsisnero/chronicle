require "json"

module Clarity
  # Pure, newline-delimited persistence format for immutable event logs.
  module EventLogCodec
    extend self

    FORMAT         = "clarity.event-log"
    FORMAT_VERSION = 1

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
      value = JSON.parse(line).as_h
      Event.new(
        schema_version: value["schema_version"].as_i.to_u16,
        sequence: value["sequence"].as_i.to_u64,
        id: value["id"].as_s,
        type: value["type"].as_s,
        actor: value["actor"].as_s,
        caused_by: nullable_string(value["caused_by"]),
        timestamp: Time::Format::RFC_3339.parse(value["timestamp"].as_s),
        payload: value["payload"].to_json
      )
    rescue JSON::ParseException | KeyError | TypeCastError | ArgumentError | OverflowError
      raise InvalidLogEncodingError.new("invalid event record")
    end

    private def nullable_string(value : JSON::Any) : String?
      value.raw.nil? ? nil : value.as_s
    end
  end
end
