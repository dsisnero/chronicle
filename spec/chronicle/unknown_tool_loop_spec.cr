require "../spec_helper"

# Unknown-tool refusal in the LLM behavior tool loop. Ported from activegraph
# tests/test_llm_tool_loop.py::test_unknown_tool_call_triggers_behavior_failed:
# an @llm_behavior declares tools; the model asks for a tool the behavior did
# not declare; the runtime refuses and emits behavior.failed with
# reason="tool.unknown_tool" and a `tool` extra instead of crashing.

class UnknownToolLoopModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.tool_call("c1", "nope_not_a_tool", JSON.parse(%({})))
      ),
      Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
      "raw",
      "msg_1",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module UnknownToolPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
  end

  pack(name: "llmtool", version: "0.1.0")
end

private def unknown_tool_behavior_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(UnknownToolLoopModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(UnknownToolLoopModel).new(model: UnknownToolLoopModel.new, preamble: "")
  la = Chronicle::LogAgent(UnknownToolLoopModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(
    Chronicle::FixedModelExecutor(UnknownToolLoopModel).new(UnknownToolLoopModel.new),
  )
  rt = Chronicle::Runtime(UnknownToolLoopModel).new(
    store: store,
    log_agent: la,
    graph: graph,
    model_effect_worker: worker,
    tools: [Chronicle::Tool.new("my_tool", "t") { |args| %({"answer":"ok"}) }],
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "refuses an undeclared tool call and emits behavior.failed with reason tool.unknown_tool" do
    store, graph, rt = unknown_tool_behavior_runtime
    rt.load_pack(UnknownToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    failed = store.iter_events.find { |e| e.type == "behavior.failed" }
    failed.should_not be_nil
    payload = JSON.parse(failed.not_nil!.payload).as_h
    payload["reason"]?.should eq("tool.unknown_tool")
  end

  it "records the requested tool name in the behavior.failed payload" do
    store, graph, rt = unknown_tool_behavior_runtime
    rt.load_pack(UnknownToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    failed = store.iter_events.find { |e| e.type == "behavior.failed" }.not_nil!
    JSON.parse(failed.payload).as_h["tool"]?.should eq("nope_not_a_tool")
  end
end
