require "json"

module Chronicle
  # Structured logging — the log schema is the operator contract
  # (CONTRACT v0.8 #6–#7, #16). The framework emits structured logs; the
  # schema below is documented and stable, so dashboards built against
  # these field names keep working across framework versions.
  #
  # This module is the Sans-IO formatting core: it turns a structured
  # record into one compact JSON line and builds `extra=` dicts for log
  # calls. The actual I/O (writing to a stream) happens at the platform
  # edge; the pure formatter/extras/redaction logic lives here.
  module Logging
    extend self

    # The documented operator-facing log schema. Fields appear when
    # applicable; fields that don't apply are omitted (not nulled).
    # Add fields at the END of this list.
    LOG_FIELDS = [
      "timestamp",
      "level",
      "logger",
      "message",
      "run_id",
      "event_id",
      "behavior",
      "tool",
      "model",
      "cache_hit",
      "cost_usd",
      "latency_seconds",
      "reason",
      "error_type",
      "error_message",
      "doc_url",
    ]

    # Reserved attributes that collide with stdlib log-record internals.
    # Any `extra=` field that collides is renamed (prefix `ag_`).
    RESERVED_RECORD_ATTRS = Set{
      "args", "asctime", "created", "exc_info", "exc_text", "filename",
      "funcName", "levelname", "levelno", "lineno", "message", "module",
      "msecs", "msg", "name", "pathname", "process", "processName",
      "relativeCreated", "stack_info", "thread", "threadName",
      "taskName",
    }

    @@payload_redactor : Proc(Hash(String, JSON::Any), Hash(String, JSON::Any))? = nil

    # Install a redactor that runs on any payload before it enters a log
    # record's extras. Idempotent. Pass nil to remove. Name mirrors
    # upstream set_payload_redactor.
    # ameba:disable Naming/AccessorMethodName
    def set_payload_redactor(fn : Proc(Hash(String, JSON::Any), Hash(String, JSON::Any))?) : Nil
      @@payload_redactor = fn
    end

    # Apply the configured redactor (or identity).
    def redact_payload(payload : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      if fn = @@payload_redactor
        fn.call(payload)
      else
        payload
      end
    end

    # Format one structured log record as a single-line JSON object.
    # Required fields (timestamp/level/logger/message) are always present;
    # documented extras are emitted only when present; undocumented fields
    # are dropped so the schema stays stable. Ported from upstream
    # JsonLineFormatter.format.
    def format_line(
      *,
      timestamp : String,
      level : String,
      logger : String,
      message : String,
      extras : Hash(String, JSON::Any),
    ) : String
      required = {
        "timestamp" => JSON::Any.new(timestamp),
        "level"     => JSON::Any.new(level),
        "logger"    => JSON::Any.new(logger),
        "message"   => JSON::Any.new(message),
      }
      merged = LOG_FIELDS.reduce(required) do |acc, key|
        if acc.has_key?(key)
          acc
        elsif value = extras[key]?
          acc.merge({key => value})
        else
          acc
        end
      end
      Prompt.canonical_json(JSON::Any.new(merged))
    end

    # Build an `extra=` dict for a log call, dropping nil values and
    # renaming reserved log-record attribute names. Ported from upstream
    # runtime_log_extra.
    def runtime_log_extra(**fields : (String | Int32 | Int64 | Float64 | Bool | Nil | JSON::Any)) : Hash(String, JSON::Any)
      out = {} of String => JSON::Any
      fields.each do |key, value|
        next if value.nil?

        name = key.to_s
        if RESERVED_RECORD_ATTRS.includes?(name)
          out["ag_#{name}"] = to_json_any(value)
        else
          out[name] = to_json_any(value)
        end
      end
      out
    end

    private def to_json_any(value : (String | Int32 | Int64 | Float64 | Bool | Nil | JSON::Any)) : JSON::Any
      case value
      when String
        JSON::Any.new(value)
      when Int32
        JSON::Any.new(value.to_i64)
      when Int64
        JSON::Any.new(value)
      when Float64
        JSON::Any.new(value)
      when Bool
        JSON::Any.new(value)
      when JSON::Any
        value
      else
        JSON::Any.new(nil)
      end
    end
  end
end
