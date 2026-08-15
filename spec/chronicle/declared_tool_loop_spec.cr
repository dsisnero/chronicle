require "../spec_helper"

# Declared-tool invocation in the LLM behavior tool loop. Ported from
# activegraph tests/test_llm_tool_loop.py::test_one_tool_turn and
# test_two_tool_turns_chain: when the model asks for a declared tool, the
# runtime invokes it (recording tool.requested / tool.responded), feeds the
# result back into the conversation, and re-calls the model until a non-tool
# response arrives. The behavior handler sees only the final output.

class DeclaredToolLoopModel
  include Crig::Completion::CompletionModel

  class_property call_count = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    self.class.call_count += 1
    case self.class.call_count
    when 1
      response(tool: "c1", name: "llmtool.my_tool", args: %({"q":"1"}))
    when 2
      response(tool: "c2", name: "llmtool.my_tool", args: %({"q":"2"}))
    else
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("done")
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_final",
      )
    end
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end

  private def response(tool : String, name : String, args : String) : Crig::Completion::CompletionResponse(String)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.tool_call(tool, name, JSON.parse(args))
      ),
      Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
      "raw",
      "msg_#{tool}",
    )
  end
end

module DeclaredToolPack
  include Chronicle::Packs::DSL

  class_property captured_output : String? = nil

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    DeclaredToolPack.captured_output = output
  end

  @[Tool(name: "my_tool", description: "t")]
  def my_tool(args : String) : String
    JSON.build do |json|
      json.object do
        json.field "answer", args
      end
    end
  end

  pack(name: "llmtool", version: "0.1.0")
end

class ForeverToolLoopModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    response(tool: "c#{rand(1000)}", name: "exhausted.my_tool", args: %({"q":"x"}))
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end

  private def response(tool : String, name : String, args : String) : Crig::Completion::CompletionResponse(String)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.tool_call(tool, name, JSON.parse(args))
      ),
      Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
      "raw",
      "msg_#{tool}",
    )
  end
end

module ExhaustedToolPack
  include Chronicle::Packs::DSL

  class_property captured_output : String? = nil

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"], max_tool_turns: 2)]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    ExhaustedToolPack.captured_output = output
  end

  @[Tool(name: "my_tool", description: "t")]
  def my_tool(args : String) : String
    JSON.build do |json|
      json.object do
        json.field "answer", args
      end
    end
  end

  pack(name: "exhausted", version: "0.1.0")
end

private def declared_tool_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(DeclaredToolLoopModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(DeclaredToolLoopModel).new(model: DeclaredToolLoopModel.new, preamble: "")
  la = Chronicle::LogAgent(DeclaredToolLoopModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(
    Chronicle::FixedModelExecutor(DeclaredToolLoopModel).new(DeclaredToolLoopModel.new),
  )
  rt = Chronicle::Runtime(DeclaredToolLoopModel).new(
    store: store,
    log_agent: la,
    graph: graph,
    model_effect_worker: worker,
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "invokes a declared tool, feeds the result back, and passes the final output to the handler" do
    DeclaredToolPack.captured_output = nil
    DeclaredToolLoopModel.call_count = 0
    store, graph, rt = declared_tool_runtime
    rt.load_pack(DeclaredToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    DeclaredToolPack.captured_output.should eq("done")
    DeclaredToolLoopModel.call_count.should eq(3)
    store.iter_events.any? { |e| e.type == "tool.requested" }.should be_true
    store.iter_events.any? { |e| e.type == "tool.responded" }.should be_true
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_true
  end

  it "records tool.requested before tool.responded and links them causally" do
    DeclaredToolLoopModel.call_count = 0
    store, graph, rt = declared_tool_runtime
    rt.load_pack(DeclaredToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    store.iter_events.count { |e| e.type == "tool.requested" }.should eq(2)
    store.iter_events.count { |e| e.type == "tool.responded" }.should eq(2)
    events = store.iter_events.to_a
    req = events.find! { |e| e.type == "tool.requested" }
    resp = events.find! { |e| e.type == "tool.responded" }
    resp.caused_by.should eq(req.id)
    (events.index(req).not_nil! < events.index(resp).not_nil!).should be_true
  end

  it "fails loud with reason tool.max_turns_exhausted when the model never returns a non-tool response" do
    ExhaustedToolPack.captured_output = nil
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    model = ForeverToolLoopModel.new
    agent = Crig::Agent(ForeverToolLoopModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(ForeverToolLoopModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(ForeverToolLoopModel).new(model))
    rt = Chronicle::Runtime(ForeverToolLoopModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
    )
    rt.load_pack(ExhaustedToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    ExhaustedToolPack.captured_output.should be_nil
    failures = store.iter_events.select { |e| e.type == "behavior.failed" }
    failures.should_not be_empty
    payloads = failures.map(&.payload)
    payloads.any? { |p| p.includes?("tool.max_turns_exhausted") }.should be_true
    store.iter_events.count { |e| e.type == "tool.responded" }.should eq(2)
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_false
  end
end
