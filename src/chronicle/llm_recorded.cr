require "json"
require "digest/sha256"

module Chronicle
  # The LLMProvider protocol every provider implements (CONTRACT v0.6 #3,
  # extended in v0.7, additively widened in v1.0.2 #1). Narrow, explicit,
  # keyword-only. Reference implementations are platform-edge adapters;
  # tests use RecordedLLMProvider / RecordingLLMProvider; the demo ships a
  # scripted provider.
  #
  # A provider does three things plus two declarations:
  #
  #   * complete(): run a single non-streaming completion. v0.7 adds an
  #     optional tools= parameter; when non-empty, the model is allowed to
  #     return tool_use blocks in the response.
  #   * estimate_cost(): turn token counts into USD (String).
  #   * count_tokens(): input token count for the prompt about to be sent.
  #   * recognizes_model(name): True when name belongs to a model family
  #     this provider serves (v1.0.2 #1).
  #   * supports_native_structured_output(model): True when the provider can
  #     enforce output_schema natively for model (CONTRACT v1.3 #1).
  #
  # No streaming, no multi-model orchestration — those are deferred. Tool
  # use IS in v0.7, but the loop is orchestrated by the runtime, not the
  # provider.
  abstract class LLMProvider
    # The model name to use when an @[LLMBehavior] didn't pin one (v1.0.2
    # #1).
    def default_model : String
      "claude-sonnet-4-5"
    end

    abstract def complete(
      system : String,
      messages : Array(LLMMessage),
      model : String,
      max_tokens : Int32,
      temperature : Float64,
      top_p : Float64,
      output_schema : T.class,
      timeout_seconds : Float64,
      tools : Array(Hash(String, JSON::Any))? = nil,
      structured_output_mode : String = "prompt",
    ) : LLMResponse forall T

    abstract def estimate_cost(input_tokens : Int32, output_tokens : Int32, model : String) : String

    abstract def count_tokens(system : String, messages : Array(LLMMessage), model : String) : Int32

    # True when `name` belongs to a model family this provider serves.
    # Permissive by default: unknown names return False so the runtime
    # passes them through without a diagnostic.
    def recognizes_model(name : String) : Bool
      false
    end

    # True when the provider can enforce `output_schema` natively for
    # `model` (constrained decoding). Additive — providers that pre-date
    # v1.3 resolve to the prompt-embedded path.
    def supports_native_structured_output(model : String) : Bool
      false
    end
  end

  # Fixture-based LLM providers (CONTRACT v0.6 #12 + decision-3 adjustment
  # for `recorded_at`). Ported from activegraph.llm.recorded.
  #
  #   RecordedLLMProvider  — looks up fixtures by prompt hash. Tests run
  #                          against this. Raises if a fixture is missing
  #                          (so tests fail loud rather than regressing
  #                          into live calls).
  #   RecordingLLMProvider — wraps another provider, mirrors every call to
  #                          disk as a fixture file. Use once with --record
  #                          to seed fixtures, then commit them.
  #
  # Fixture file layout (<sha256_hex>.json):
  #
  #     {
  #       "prompt_hash": "<sha256_hex>",
  #       "recorded_at": "2026-05-15T10:32:01Z",   # outside the hash
  #       "model":       "claude-sonnet-4-5",
  #       "prompt": { ... hashed payload ... },
  #       "response": { ... LLMResponse wire form ... }
  #     }
  #
  # `recorded_at` is intentionally OUTSIDE the hashed `prompt` payload so it
  # doesn't perturb lookups but stays available for debugging fixture drift.

  # Reads fixtures from a directory keyed by prompt hash. Missing fixtures
  # raise LLMBehaviorError (reason `llm.fixture_missing`) so the test fails
  # loud — there is no silent fallthrough to a real call.
  class RecordedLLMProvider < LLMProvider
    getter fixtures_dir : String

    def initialize(
      @fixtures_dir : String,
      @structured_output_mode : String = "prompt",
    )
    end

    # Fixture-backed: claim every name so cross-provider validation doesn't
    # fire against recorded responses.
    def recognizes_model(name : String) : Bool
      true
    end

    def supports_native_structured_output(model : String) : Bool
      @structured_output_mode == "native"
    end

    def complete(
      system : String,
      messages : Array(LLMMessage),
      model : String,
      max_tokens : Int32,
      temperature : Float64,
      top_p : Float64,
      output_schema : T.class,
      timeout_seconds : Float64,
      tools : Array(Hash(String, JSON::Any))? = nil,
      structured_output_mode : String = "prompt",
    ) : LLMResponse forall T
      payload = Prompt.canonical_prompt_payload(
        model: model,
        system: system,
        messages: messages,
        output_schema_json: Prompt.schema_to_json(output_schema),
        max_tokens: max_tokens,
        temperature: temperature,
        top_p: top_p,
        deterministic: temperature == 0.0 && top_p == 1.0,
        tools: tools,
        structured_output_mode: structured_output_mode,
      )
      prompt_hash = Prompt.hash_payload(payload)
      path = File.join(@fixtures_dir, "#{prompt_hash}.json")
      unless File.exists?(path)
        raise LLMBehaviorError.new(
          "llm.fixture_missing",
          "no recorded fixture for prompt_hash=#{prompt_hash} in #{@fixtures_dir}",
          {"prompt_hash" => JSON::Any.new(prompt_hash), "fixtures_dir" => JSON::Any.new(@fixtures_dir)},
        )
      end
      data = JSON.parse(File.read(path)).as_h
      response_from_fixture(data["response"].as_h)
    end

    def estimate_cost(input_tokens : Int32, output_tokens : Int32, model : String) : String
      "0"
    end

    def count_tokens(system : String, messages : Array(LLMMessage), model : String) : Int32
      total = system.size + messages.sum(&.content.size)
      {1, total // 4}.max
    end

    # Reconstruct an LLMResponse from a fixture's `response` blob. `parsed`
    # stays JSON::Any (Crystal has no runtime Pydantic re-validation);
    # tool_calls round-trip through their wire form.
    def response_from_fixture(rdata : Hash(String, JSON::Any)) : LLMResponse
      LLMResponse.new(
        raw_text: fixture_string(rdata, "raw_text", ""),
        parsed: rdata["parsed"]?,
        input_tokens: fixture_int(rdata, "input_tokens", 0),
        output_tokens: fixture_int(rdata, "output_tokens", 0),
        cost_usd: fixture_string(rdata, "cost_usd", "0"),
        latency_seconds: fixture_float(rdata, "latency_seconds", 0.0),
        model: fixture_string(rdata, "model", "?"),
        finish_reason: fixture_string(rdata, "finish_reason", "end_turn"),
        seed: rdata["seed"]?.try(&.as_i.to_i64),
        cache_hit: false,
        provider_meta: rdata["provider_meta"]?.try(&.as_h?) || {} of String => JSON::Any,
        tool_calls: fixture_tool_calls(rdata),
      )
    end

    private def fixture_string(rdata : Hash(String, JSON::Any), key : String, default : String) : String
      rdata[key]?.try(&.as_s?) || default
    end

    private def fixture_int(rdata : Hash(String, JSON::Any), key : String, default : Int32) : Int32
      rdata[key]?.try(&.as_i.to_i32) || default
    end

    private def fixture_float(rdata : Hash(String, JSON::Any), key : String, default : Float64) : Float64
      rdata[key]?.try(&.as_f) || default
    end

    private def fixture_tool_calls(rdata : Hash(String, JSON::Any)) : Array(ToolCall)?
      raw_calls = rdata["tool_calls"]?.try(&.as_a)
      return nil unless raw_calls

      raw_calls.map do |call|
        h = call.as_h
        args = h["args"]?.try(&.as_h?) || {} of String => JSON::Any
        ToolCall.new(
          id: h["id"]?.try(&.as_s) || "",
          name: h["name"]?.try(&.as_s) || "",
          args: args,
        )
      end
    end
  end

  # Wraps a real provider and persists responses to fixtures. Use once (with
  # --record opt-in) to seed fixtures, then commit them and run tests against
  # RecordedLLMProvider thereafter.
  class RecordingLLMProvider < LLMProvider
    getter inner : LLMProvider

    def initialize(@inner : LLMProvider, @fixtures_dir : String)
      Dir.mkdir_p(@fixtures_dir)
    end

    def default_model : String
      @inner.default_model
    end

    def recognizes_model(name : String) : Bool
      @inner.recognizes_model(name)
    end

    def supports_native_structured_output(model : String) : Bool
      @inner.supports_native_structured_output(model)
    end

    def complete(
      system : String,
      messages : Array(LLMMessage),
      model : String,
      max_tokens : Int32,
      temperature : Float64,
      top_p : Float64,
      output_schema : T.class,
      timeout_seconds : Float64,
      tools : Array(Hash(String, JSON::Any))? = nil,
      structured_output_mode : String = "prompt",
    ) : LLMResponse forall T
      response = @inner.complete(
        system: system,
        messages: messages,
        model: model,
        max_tokens: max_tokens,
        temperature: temperature,
        top_p: top_p,
        output_schema: output_schema,
        timeout_seconds: timeout_seconds,
        tools: tools,
        structured_output_mode: structured_output_mode,
      )

      payload = Prompt.canonical_prompt_payload(
        model: model,
        system: system,
        messages: messages,
        output_schema_json: Prompt.schema_to_json(output_schema),
        max_tokens: max_tokens,
        temperature: temperature,
        top_p: top_p,
        deterministic: temperature == 0.0 && top_p == 1.0,
        tools: tools,
        structured_output_mode: structured_output_mode,
      )
      prompt_hash = Prompt.hash_payload(payload)

      fixture = {
        "prompt_hash" => JSON::Any.new(prompt_hash),
        "recorded_at" => JSON::Any.new(now_iso),
        "model"       => JSON::Any.new(model),
        "prompt"      => JSON::Any.new(payload),
        "response"    => JSON.parse(response.to_json),
      }

      path = File.join(@fixtures_dir, "#{prompt_hash}.json")
      File.write(path, Prompt.canonical_json(JSON::Any.new(fixture), spaced: true))
      response
    end

    def estimate_cost(input_tokens : Int32, output_tokens : Int32, model : String) : String
      @inner.estimate_cost(input_tokens: input_tokens, output_tokens: output_tokens, model: model)
    end

    def count_tokens(system : String, messages : Array(LLMMessage), model : String) : Int32
      @inner.count_tokens(system: system, messages: messages, model: model)
    end

    private def now_iso : String
      Time.utc.to_rfc3339
    end
  end

  # A shipped provider family descriptor used by the cross-provider mismatch
  # check (CONTRACT v1.0.2 #1 (b), upstream `_which_shipped_provider_claims`).
  # Anthropic/OpenAI shipped providers are deferred in Chronicle; this class
  # lets the decision logic stay fully testable without real shipped provider
  # classes. Configuring a provider of class `provider_class` excludes that
  # family from the "someone else claims this name" lookup, mirroring
  # upstream's `exclude=type(provider)`.
  class ShippedProviderFamily
    getter name : String
    getter default_model : String
    getter provider_class : LLMProvider.class
    @recognizes : Proc(String, Bool)

    def initialize(
      @name : String,
      @default_model : String,
      @provider_class : LLMProvider.class,
      &@recognizes : String -> Bool
    )
    end

    def recognizes?(name : String) : Bool
      @recognizes.call(name)
    end
  end
end
