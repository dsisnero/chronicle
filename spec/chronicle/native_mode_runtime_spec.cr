require "../spec_helper"

# Native structured-output mode wiring (CONTRACT v1.3 #1): the runtime resolves
# a behavior's structured-output mode ("native" vs "prompt") from the opt-in
# flag, the provider capability claim for the resolved model, and the schema
# subset pre-flight; the resolved mode rides every llm.requested payload and
# contributes to the prompt hash only when native (a flag/capability flip
# changes the cache key, so record-vs-replay mode drift surfaces as a cache
# miss). Ported from activegraph tests/test_llm_native_structured_output.py
# test_native_mode_end_to_end_and_requested_payload /
# test_flag_on_but_no_capability_resolves_prompt /
# test_flag_on_but_schema_outside_subset_resolves_prompt /
# test_prompt_mode_hashable_has_no_mode_key.

class NativeModeModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(%({"n":42}))
      ),
      Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
      "raw",
      "msg_native",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module NativeModePack
  include Chronicle::Packs::DSL

  struct Out
    include JSON::Serializable
    property n : Int32
  end

  struct LooseOut
    include JSON::Serializable
    property n : Int32
    property optional : String? = nil
  end

  class_property captured : Int32? = nil

  @[LLMBehavior(name: "extract", on: ["object.created"], where: {"type" => "document"}, output_schema: Out)]
  def extract(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : Out)
    NativeModePack.captured = output.n
  end

  pack(name: "nativemode", version: "0.1.0")
end

module NativeLooseModePack
  include Chronicle::Packs::DSL

  class_property captured : String? = nil

  @[LLMBehavior(name: "loose", on: ["object.created"], where: {"type" => "document"}, output_schema: NativeModePack::LooseOut)]
  def loose(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : NativeModePack::LooseOut)
    NativeLooseModePack.captured = output.n.to_s
  end

  pack(name: "nativeloose", version: "0.1.0")
end

private def native_mode_runtime(flag : Bool, capability : Proc(String, Bool)?, model : NativeModeModel = NativeModeModel.new)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(NativeModeModel).new(model: model, preamble: "")
  la = Chronicle::LogAgent(NativeModeModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(
    Chronicle::FixedModelExecutor(NativeModeModel).new(model),
  )
  rt = Chronicle::Runtime(NativeModeModel).new(
    store: store, log_agent: la, graph: graph, model_effect_worker: worker,
    native_structured_output: flag,
    native_capability: capability,
  )
  {store, graph, rt}
end

private def native_requested_mode(rt) : String
  request = rt.store.iter_events.find! { |e| e.type == "llm.requested" }
  JSON.parse(request.payload).as_h["structured_output_mode"].as_s
end

private def native_request_hash(rt) : String
  request = rt.store.iter_events.find! { |e| e.type == "llm.requested" }
  JSON.parse(request.payload).as_h["request_hash"].as_s
end

describe "Native structured-output mode wiring" do
  it "resolves native end-to-end and rides the llm.requested payload" do
    store, graph, rt = native_mode_runtime(true, ->(_model : String) { true })
    rt.load_pack(NativeModePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    native_requested_mode(rt).should eq("native")
    NativeModePack.captured.should eq(42)
    store.iter_events.any? { |e| e.type == "behavior.failed" }.should be_false
  end

  it "resolves prompt when the opt-in flag is off and stays byte-identical to prompt mode" do
    _store, graph, rt = native_mode_runtime(false, ->(_model : String) { true })
    rt.load_pack(NativeModePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    native_requested_mode(rt).should eq("prompt")
  end

  it "resolves prompt when the provider does not claim the capability" do
    _store, graph, rt = native_mode_runtime(true, nil)
    rt.load_pack(NativeModePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    native_requested_mode(rt).should eq("prompt")
  end

  it "resolves prompt when the schema is outside the native subset" do
    _store, graph, rt = native_mode_runtime(true, ->(_model : String) { true })
    rt.load_pack(NativeLooseModePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    native_requested_mode(rt).should eq("prompt")
  end

  it "mode contributes to the prompt hash only when native (a mode flip changes the cache key)" do
    _store, graph, rt_prompt = native_mode_runtime(false, ->(_model : String) { true })
    rt_prompt.load_pack(NativeModePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt_prompt.run_until_idle

    _store2, graph2, rt_native = native_mode_runtime(true, ->(_model : String) { true })
    rt_native.load_pack(NativeModePack::PACK)
    graph2.add_object("document", %({"title":"hello"}))
    rt_native.run_until_idle

    native_request_hash(rt_prompt).should_not eq(native_request_hash(rt_native))
  end
end
