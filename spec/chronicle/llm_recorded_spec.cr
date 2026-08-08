require "../spec_helper"

# RecordedLLMProvider + RecordingLLMProvider (CONTRACT v0.6 #12 +
# decision-3 adjustment). Recording produces fixtures keyed by prompt hash
# with `recorded_at` outside the hashed content; recorded mode reads them;
# a missing fixture raises so tests fail loud rather than calling out.

struct FixtureOut
  include JSON::Serializable

  getter n : Int32
end

# Stub inner provider for recording tests (Crystal-native; upstream uses a
# Python _StubInner class).
class StubInnerProvider < Chronicle::LLMProvider
  getter calls = [] of String

  def complete(
    system : String,
    messages : Array(Chronicle::LLMMessage),
    model : String,
    max_tokens : Int32,
    temperature : Float64,
    top_p : Float64,
    output_schema : T.class,
    timeout_seconds : Float64,
    tools : Array(Hash(String, JSON::Any))? = nil,
    structured_output_mode : String = "prompt",
  ) : Chronicle::LLMResponse forall T
    @calls << "complete"
    Chronicle::LLMResponse.new(
      raw_text: %({"n": 1}),
      parsed: JSON.parse(%({"n":1})),
      input_tokens: 5,
      output_tokens: 2,
      cost_usd: "0.0001",
      latency_seconds: 0.05,
      model: model,
      finish_reason: "end_turn",
    )
  end

  def estimate_cost(input_tokens : Int32, output_tokens : Int32, model : String) : String
    "0.0001"
  end

  def count_tokens(system : String, messages : Array(Chronicle::LLMMessage), model : String) : Int32
    5
  end
end

private def record_fixture(dir : String, output_schema : T.class = Nil.class) : Chronicle::LLMResponse forall T
  inner = StubInnerProvider.new
  rec = Chronicle::RecordingLLMProvider.new(inner, dir)
  rec.complete(
    system: "sys",
    messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")],
    model: "claude-sonnet-4-5",
    max_tokens: 64,
    temperature: 0.0,
    top_p: 1.0,
    output_schema: output_schema,
    timeout_seconds: 30.0,
  )
end

describe Chronicle::RecordingLLMProvider do
  it "writes a fixture with recorded_at outside the hash" do
    dir = pack_spec_dir("llm_fixtures_recorded_at")
    record_fixture(dir, FixtureOut)

    files = Dir.children(dir).reject(&.starts_with?("._"))
    files.size.should eq(1)
    path = File.join(dir, files.first)
    data = JSON.parse(File.read(path)).as_h

    data.has_key?("recorded_at").should be_true
    data["recorded_at"].as_s.should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    data["prompt"].as_h.has_key?("recorded_at").should be_false
    files.first.should eq("#{data["prompt_hash"].as_s}.json")
  end
end

describe Chronicle::RecordedLLMProvider do
  it "reads back a response recorded with the same prompt" do
    dir = pack_spec_dir("llm_fixtures_readback")
    record_fixture(dir, FixtureOut)

    recorded = Chronicle::RecordedLLMProvider.new(dir)
    response = recorded.complete(
      system: "sys",
      messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")],
      model: "claude-sonnet-4-5",
      max_tokens: 64,
      temperature: 0.0,
      top_p: 1.0,
      output_schema: FixtureOut,
      timeout_seconds: 30.0,
    )
    response.raw_text.should eq(%({"n": 1}))
    response.parsed.not_nil!.as_h["n"].as_i.should eq(1)
  end

  it "raises LLMBehaviorError with reason llm.fixture_missing on a missing fixture" do
    dir = pack_spec_dir("llm_fixtures_missing")
    recorded = Chronicle::RecordedLLMProvider.new(dir)
    error = expect_raises(Chronicle::LLMBehaviorError) do
      recorded.complete(
        system: "sys",
        messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")],
        model: "claude-sonnet-4-5",
        max_tokens: 64,
        temperature: 0.0,
        top_p: 1.0,
        output_schema: FixtureOut,
        timeout_seconds: 30.0,
      )
    end
    error.reason.should eq("llm.fixture_missing")
    error.payload_extras.has_key?("prompt_hash").should be_true
  end

  it "recognizes every model (fixture-backed)" do
    Chronicle::RecordedLLMProvider.new(pack_spec_dir("llm_fixtures_recognize")).recognizes_model("anything").should be_true
  end

  it "supports native structured output only when constructed with native mode" do
    prompt_mode = Chronicle::RecordedLLMProvider.new(pack_spec_dir("llm_fixtures_prompt_mode"))
    prompt_mode.supports_native_structured_output("m").should be_false

    native = Chronicle::RecordedLLMProvider.new(pack_spec_dir("llm_fixtures_native_mode"), structured_output_mode: "native")
    native.supports_native_structured_output("m").should be_true
  end

  it "has a stable fixture hash across recordings of the same prompt" do
    dir = pack_spec_dir("llm_fixtures_stable")
    2.times { record_fixture(dir, FixtureOut) }
    # Same key -> one file, not two.
    Dir.children(dir).reject(&.starts_with?("._")).size.should eq(1)
  end

  it "estimates tokens as max(1, chars // 4)" do
    recorded = Chronicle::RecordedLLMProvider.new(pack_spec_dir("llm_fixtures_tokens"))
    recorded.count_tokens(system: "sys", messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hello world")], model: "m").should eq(3)
  end
end

describe Chronicle::Prompt do
  it "canonical_prompt_payload includes messages and omits recorded_at" do
    payload = Chronicle::Prompt.canonical_prompt_payload(
      model: "m",
      system: "sys",
      messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")],
      output_schema_json: nil,
      max_tokens: 64,
      temperature: 0.0,
      top_p: 1.0,
      deterministic: true,
    )
    payload["model"].as_s.should eq("m")
    payload.has_key?("recorded_at").should be_false
    payload["messages"].as_a.size.should eq(1)
  end

  it "hash_payload is stable and 64 hex chars" do
    a = Chronicle::Prompt.canonical_prompt_payload(model: "m", system: "sys", messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")], output_schema_json: nil, max_tokens: 64, temperature: 0.0, top_p: 1.0, deterministic: true)
    b = Chronicle::Prompt.canonical_prompt_payload(model: "m", system: "sys", messages: [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")], output_schema_json: nil, max_tokens: 64, temperature: 0.0, top_p: 1.0, deterministic: true)
    Chronicle::Prompt.hash_payload(a).should eq(Chronicle::Prompt.hash_payload(b))
    Chronicle::Prompt.hash_payload(a).size.should eq(64)
  end
end
