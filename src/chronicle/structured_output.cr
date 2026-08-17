require "json"

module Chronicle
  # Structured-output parsing for LLM behaviors. Ported from activegraph
  # llm/parsing.py `parse_structured_response` (CONTRACT v1.0.1 #5): the sole
  # boundary between provider raw-text output and the framework's typed
  # downstream world.
  #
  # The extraction order is upstream's: try the response verbatim; on failure
  # look for a fenced ```json block; on failure grab the first balanced
  # {..} / [..] span. Two distinct failure modes flow back as LLMBehaviorError:
  #
  #   reason="llm.parse_error"       no JSON found / JSON parse failed
  #   reason="llm.schema_violation"  JSON found but the schema rejected it
  #
  # Sans-IO: no network, no I/O — pure extraction + `JSON::Serializable`
  # validation against the caller's schema type.
  module StructuredOutput
    extend self

    FENCED_JSON_RE = Regex.new("```(?:json)?\\s*(\\{.*?\\}|\\[.*?\\])\\s*```", Regex::Options::MULTILINE)
    BRACE_RE       = Regex.new("(\\{.*\\}|\\[.*\\])", Regex::Options::MULTILINE)

    # Extract the JSON candidate recoverable from a provider's raw output
    # (upstream llm/parsing.py): the text verbatim, else a fenced ```json
    # block, else the first balanced {..} / [..] span. Nil when none is
    # recoverable.
    def extract_json(text : String) : String?
      candidate = text.strip
      return candidate if json?(candidate)
      if match = FENCED_JSON_RE.match(text) || BRACE_RE.match(text)
        return match[1]?
      end
      nil
    end

    # Parse raw provider text into a `JSON::Serializable` schema type, raising
    # `LLMBehaviorError` with reason="llm.parse_error" when no JSON is
    # recoverable and reason="llm.schema_violation" when the JSON doesn't
    # match the schema (upstream `parse_structured_response`).
    def parse(text : String, schema : T.class) : T forall T
      candidate = extract_json(text)
      if candidate.nil?
        raise LLMBehaviorError.new(
          "llm.parse_error",
          "no JSON found in response: invalid JSON",
          {
            "raw_text"   => JSON::Any.new(text),
            "underlying" => JSON::Any.new("invalid JSON"),
          },
        )
      end

      begin
        schema.from_json(candidate)
      rescue ex : JSON::SerializableError
        raise LLMBehaviorError.new(
          "llm.schema_violation",
          "response did not match schema #{schema_name(schema)}: #{ex.message}",
          {
            "raw_text"          => JSON::Any.new(text),
            "schema"            => JSON::Any.new(schema_name(schema)),
            "validation_errors" => JSON::Any.new(ex.message.to_s),
          },
        )
      rescue ex : JSON::ParseException
        raise LLMBehaviorError.new(
          "llm.parse_error",
          "no JSON found in response: #{ex.message}",
          {
            "raw_text"   => JSON::Any.new(text),
            "underlying" => JSON::Any.new(ex.message.to_s),
          },
        )
      end
    end

    private def schema_name(schema : T.class) : String forall T
      schema.name.split("::").last
    end

    private def json?(text : String) : Bool
      JSON.parse(text)
      true
    rescue JSON::ParseException
      false
    end
  end
end
