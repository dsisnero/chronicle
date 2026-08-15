require "../spec_helper"

# Missing declared tool at registration. Ported from activegraph
# tests/test_llm_tool_loop.py::test_missing_tool_at_registration_raises:
# an @llm_behavior declares a tool name the runtime cannot resolve; the
# runtime raises MissingToolError at registration (load_pack) rather than
# failing at the first LLM call.

class MissingToolPackModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("done")
      ),
      Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
      "raw",
      "msg_final",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module MissingToolPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["nonexistent_tool_name"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
  end

  pack(name: "missingtool", version: "0.1.0")
end

private def missing_tool_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(MissingToolPackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(MissingToolPackModel).new(model: MissingToolPackModel.new, preamble: "")
  la = Chronicle::LogAgent(MissingToolPackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(MissingToolPackModel).new(
    store: store,
    log_agent: la,
    graph: graph,
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "raises MissingToolError at load_pack when a declared tool cannot be resolved" do
    store, graph, rt = missing_tool_runtime
    expect_raises(Chronicle::MissingToolError) do
      rt.load_pack(MissingToolPack::PACK)
    end
  end

  it "does not record a pack.loaded event when tool resolution fails" do
    store, graph, rt = missing_tool_runtime
    begin
      rt.load_pack(MissingToolPack::PACK)
    rescue Chronicle::MissingToolError
    end
    store.iter_events.any? { |e| e.type == "pack.loaded" }.should be_false
  end
end
