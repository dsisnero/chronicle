require "../spec_helper"

# AgentHook specs: crig's hook dispatch is the supported way to observe and
# customize the AgentRunner. This verifies Chronicle's recording hook fires on
# tool call/result and completion-call events.

class HookModel
  include Crig::Completion::CompletionModel

  @calls = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    if @calls == 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.tool_call("tc_1", "search", JSON.parse(%({"q":"test"})))
        ),
        Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
        "raw",
        "msg_1",
      )
    else
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("Tool done")
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_2",
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

describe Chronicle::AgentHook do
  it "records tool.requested and tool.responded when the runner dispatches tool events" do
    store = Chronicle::MemoryEventStore.new
    hook = Chronicle::AgentHook.new(store, Chronicle::ToolCache.new)

    runner = Crig::AgentRunner(HookModel).new(HookModel.new)
      .max_turns(2)
      .preamble("Use tools.")
      .static_tools([
        Crig::Completion::ToolDefinition.new("search", "search for things", JSON::Any.new({"type" => JSON::Any.new("object")})),
      ])
      .tool_server_handle(Crig::ToolServerHandle.with_resolver("h", ->(name : String, args : String) { %({"results":[#{args}]}) }))
      .add_hook(hook)

    response = runner.run(Crig::Completion::Message.user("Search for test"))
    response.output.should eq("Tool done")

    store.iter_events.any? { |e| e.type == "tool.requested" }.should be_true
    responded = store.iter_events.find { |e| e.type == "tool.responded" }.not_nil!
    JSON.parse(responded.payload).as_h["tool"].as_s.should eq("search")
    store.iter_events.any? { |e| e.type == "llm.requested" }.should be_true
  end

  it "returns cont actions so the runner continues" do
    hook = Chronicle::AgentHook.new(nil)
    ctx = Crig::HookContext.new(is_streaming: false)
    event = Crig::StepEvent.tool_call("search", "tc_1", "id_1", %({"q":"test"}))
    hook.on_tool_call(ctx, event).kind.cont?.should be_true
  end
end
