require "../spec_helper"

# `@[LLMBehavior(output_schema:)]` schema typing end-to-end: the handler
# receives a parsed JSON::Serializable value instead of the raw output string,
# and parse/schema failures surface as `behavior.failed` with
# reason="llm.parse_error" / "llm.schema_violation". Closes the (1081)
# divergence. Ported from activegraph tests/test_llm_behavior.py
# test_llm_behavior_invokes_handler_with_parsed_output + tests/test_llm_failure.py
# test_schema_violation_becomes_behavior_failed.

class SchemaScriptedModel
  include Crig::Completion::CompletionModel

  getter calls : Int32 = 0

  def initialize(@text : String)
  end

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(@text)
      ),
      Crig::Completion::Usage.new(input_tokens: 4, output_tokens: 2),
      "raw",
      "msg_schema",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module OutputSchemaPack
  include Chronicle::Packs::DSL

  struct Claim
    include JSON::Serializable
    property text : String
    property confidence : Float64
  end

  struct Claims
    include JSON::Serializable
    property claims : Array(Claim)
  end

  class_property captured : Claims? = nil
  class_property claim_objects : Int32 = 0

  @[LLMBehavior(name: "extractor", on: ["object.created"], where: {"type" => "document"}, output_schema: Claims)]
  def extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : Claims)
    OutputSchemaPack.captured = output
    output.claims.each do |claim|
      graph.add_object("claim", JSON.build do |json|
        json.object do
          json.field "text", claim.text
          json.field "confidence", claim.confidence
        end
      end)
      OutputSchemaPack.claim_objects += 1
    end
  end

  pack(name: "outputschema", version: "0.1.0")
end

module OutputSchemaSpecHelper
  extend self

  def runtime(text : String)
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    model = SchemaScriptedModel.new(text)
    agent = Crig::Agent(SchemaScriptedModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(SchemaScriptedModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(
      Chronicle::FixedModelExecutor(SchemaScriptedModel).new(model),
    )
    rt = Chronicle::Runtime(SchemaScriptedModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
      llm_retry_initial_delay_seconds: 0.0,
    )
    rt.load_pack(OutputSchemaPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    {store, rt}
  end
end

describe "LLM behavior output_schema typing" do
  it "invokes the handler with a parsed typed value" do
    OutputSchemaPack.captured = nil
    OutputSchemaPack.claim_objects = 0
    store, rt = OutputSchemaSpecHelper.runtime(%({"claims":[{"text":"Sample claim","confidence":0.9}]}))
    rt.run_until_idle

    captured = OutputSchemaPack.captured.not_nil!
    captured.claims.size.should eq(1)
    captured.claims[0].text.should eq("Sample claim")
    captured.claims[0].confidence.should eq(0.9)
    OutputSchemaPack.claim_objects.should eq(1)

    store.iter_events.any? { |e| e.type == "behavior.failed" }.should be_false
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_true
  end

  it "folds a provider response with no recoverable JSON to llm.parse_error" do
    store, rt = OutputSchemaSpecHelper.runtime("just prose, no json at all")
    rt.run_until_idle

    failed = store.iter_events.find! { |e| e.type == "behavior.failed" }
    payload = JSON.parse(failed.payload).as_h
    payload["reason"].as_s.should eq("llm.parse_error")
    payload["raw_text"].as_s.should eq("just prose, no json at all")
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_false
  end

  it "folds a provider response that mismatches the schema to llm.schema_violation" do
    store, rt = OutputSchemaSpecHelper.runtime(%({"oops": 1}))
    rt.run_until_idle

    failed = store.iter_events.find! { |e| e.type == "behavior.failed" }
    payload = JSON.parse(failed.payload).as_h
    payload["reason"].as_s.should eq("llm.schema_violation")
    payload["raw_text"].as_s.should eq(%({"oops": 1}))
    payload["schema"].as_s.should eq("Claims")
  end
end
