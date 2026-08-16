require "../spec_helper"

# v1.0.3 #4: multi-turn tool-use messages carry full content blocks. Ported
# from activegraph tests/test_v1_0_3_tool_multiturn.py: when the LLM returns
# tool_use blocks, the next provider call's messages must contain an assistant
# turn whose content carries the originating tool calls (id + name). Without
# this the wire adapter can't reconstruct the spec-required tool_use blocks.

class MultiturnToolModel
  include Crig::Completion::CompletionModel

  class_property call_count = 0
  class_property second_call_messages : Array(Crig::Completion::Message)? = nil

  def completion(request : Crig::Completion::Request::CompletionRequest)
    self.class.call_count += 1
    if self.class.call_count == 2
      self.class.second_call_messages = request.chat_history.to_a
    end
    case self.class.call_count
    when 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).many([
          Crig::Completion::AssistantContent.text("thinking..."),
          Crig::Completion::AssistantContent.tool_call("c1", "multiturn.my_tool", JSON.parse(%({"q":"x"}))),
        ]),
        Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
        "raw",
        "msg_c1",
      )
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
end

module MultiturnToolPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
  end

  @[Tool(name: "my_tool", description: "t")]
  def my_tool(args : String) : String
    JSON.build do |json|
      json.object do
        json.field "answer", args
      end
    end
  end

  pack(name: "multiturn", version: "0.1.0")
end

describe Chronicle::Runtime do
  it "appends an assistant message carrying the tool calls to the re-call history" do
    MultiturnToolModel.call_count = 0
    MultiturnToolModel.second_call_messages = nil
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    model = MultiturnToolModel.new
    agent = Crig::Agent(MultiturnToolModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(MultiturnToolModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(MultiturnToolModel).new(model))
    rt = Chronicle::Runtime(MultiturnToolModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
    )
    rt.load_pack(MultiturnToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    MultiturnToolModel.call_count.should eq(2)
    messages = MultiturnToolModel.second_call_messages.not_nil!
    assistant = messages.find { |m| m.role.assistant? }
    assistant.should_not be_nil
    assistant_items = assistant.not_nil!.content.to_a
    text = assistant_items.compact_map do |item|
      item.as?(Crig::Completion::AssistantContent).try(&.text)
    end
    text.size.should eq(1)
    text.first.not_nil!.text.should eq("thinking...")
    call = assistant_items.compact_map do |item|
      item.as?(Crig::Completion::AssistantContent).try(&.tool_call)
    end
    call.size.should eq(1)
    call.first.id.should eq("c1")
    call.first.function.name.should eq("multiturn.my_tool")
  end
end
