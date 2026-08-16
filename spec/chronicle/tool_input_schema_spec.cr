require "../spec_helper"

# Tool input-schema validation in the LLM behavior tool loop. Ported from
# activegraph tests/test_llm_tool_loop.py::test_bad_tool_input_emits_invalid_input_failure:
# a tool declares an input schema; the model calls it with arguments that fail
# validation; the runtime emits behavior.failed with reason="tool.invalid_input"
# instead of invoking the tool.

class BadInputToolModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.tool_call("c1", "badinput.my_tool", JSON.parse(%({"wrong":"x"})))
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

module BadInputToolPack
  include Chronicle::Packs::DSL

  class_property captured_output : String? = nil
  class_property invoked : Bool = false

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    BadInputToolPack.captured_output = output
  end

  struct MyToolIn
    include JSON::Serializable

    getter q : String
  end

  @[Tool(name: "my_tool", description: "t", input_schema: MyToolIn)]
  def my_tool(args : String) : String
    BadInputToolPack.invoked = true
    JSON.build do |json|
      json.object do
        json.field "answer", args
      end
    end
  end

  pack(name: "badinput", version: "0.1.0")
end

private def bad_input_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BadInputToolModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  model = BadInputToolModel.new
  agent = Crig::Agent(BadInputToolModel).new(model: model, preamble: "")
  la = Chronicle::LogAgent(BadInputToolModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(BadInputToolModel).new(model))
  rt = Chronicle::Runtime(BadInputToolModel).new(
    store: store,
    log_agent: la,
    graph: graph,
    model_effect_worker: worker,
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "fails loud with reason tool.invalid_input when tool args fail schema validation" do
    BadInputToolPack.captured_output = nil
    BadInputToolPack.invoked = false
    store, graph, rt = bad_input_runtime
    rt.load_pack(BadInputToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    BadInputToolPack.captured_output.should be_nil
    BadInputToolPack.invoked.should be_false
    failures = store.iter_events.select { |e| e.type == "behavior.failed" }
    failures.should_not be_empty
    payload = JSON.parse(failures.first.not_nil!.payload).as_h
    payload["reason"]?.should eq("tool.invalid_input")
    payload["tool"]?.should eq("badinput.my_tool")
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_false
  end
end
