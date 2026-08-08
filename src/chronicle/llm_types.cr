require "json"

module Chronicle
  # LLM data types. Ported from activegraph.llm.types (v0.7 shapes).
  #
  #   LLMMessage  — a single role-tagged message in the conversation history.
  #                 v0.7 adds the "tool" role and `tool_use_id` so the
  #                 LLM ↔ tool turn loop can echo results back.
  #   ToolCall    — a single tool-call request returned by the model inside
  #                 an LLMResponse.tool_calls. v0.7 addition.
  #   LLMResponse — what every provider's `complete()` returns: raw text,
  #                 parsed structured output (if a schema was requested),
  #                 token counts, cost, latency, model id, finish reason, a
  #                 `cache_hit` flag, and an optional list of `tool_calls`.
  #
  # These are plain JSON::Serializable structs: their wire form is produced
  # by `to_json` / consumed by `from_json`, and nilable fields are omitted
  # when absent so single-turn fixtures keep byte-identical serialization.
  # Anything provider-specific (Anthropic stop reasons, retry-after seconds)
  # goes into `provider_meta` so the contract stays narrow.

  enum Role
    User
    Assistant
    Tool
  end

  # One message in a chat-style prompt. The `system` prompt is separate
  # (passed as its own argument), matching how the SDKs want it. The Role
  # enum serializes to its underscored member name (`user`/`assistant`/`tool`)
  # via JSON::Serializable's default enum handling.
  struct LLMMessage
    include JSON::Serializable

    getter role : Role
    getter content : String
    getter tool_use_id : String?
    getter tool_name : String?
    getter tool_calls : Array(ToolCall)?

    def initialize(
      @role : Role,
      @content : String,
      @tool_use_id : String? = nil,
      @tool_name : String? = nil,
      @tool_calls : Array(ToolCall)? = nil,
    )
    end
  end

  # A single tool-call request returned inside LLMResponse.tool_calls. `id`
  # is the provider-assigned identifier matched back by the runtime as
  # LLMMessage.tool_use_id; `name` matches the tool's name; `args` is the
  # JSON-shaped argument payload.
  struct ToolCall
    include JSON::Serializable

    getter id : String
    getter name : String
    getter args : Hash(String, JSON::Any)

    def initialize(@id : String, @name : String, @args : Hash(String, JSON::Any))
    end
  end

  # Normalized result of a provider `complete()` call. `parsed` carries the
  # structured output when a schema was requested; when `finish_reason`
  # indicates tool use, `tool_calls` is non-empty and the runtime enters the
  # turn loop instead of handing `parsed` to the handler.
  struct LLMResponse
    include JSON::Serializable

    getter raw_text : String
    getter parsed : JSON::Any?
    getter input_tokens : Int32
    getter output_tokens : Int32
    getter cost_usd : String
    getter latency_seconds : Float64
    getter model : String
    getter finish_reason : String
    getter seed : Int64?
    getter? cache_hit : Bool
    getter provider_meta : Hash(String, JSON::Any)
    getter tool_calls : Array(ToolCall)?

    def initialize(
      @raw_text : String,
      @parsed : JSON::Any?,
      @input_tokens : Int32,
      @output_tokens : Int32,
      @cost_usd : String,
      @latency_seconds : Float64,
      @model : String,
      @finish_reason : String,
      @seed : Int64? = nil,
      @cache_hit : Bool = false,
      @provider_meta : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @tool_calls : Array(ToolCall)? = nil,
    )
    end
  end
end
