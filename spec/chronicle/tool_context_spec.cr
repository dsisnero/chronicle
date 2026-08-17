require "../spec_helper"

# ToolContext (upstream tools/context.py, CONTRACT v0.7 #5): the narrow surface
# a tool function body sees — behavior_name, event_id, frame, idempotency_key,
# timeout_seconds, and external_io_mode (default "forbid"). The runtime threads
# one into every tool invocation so mode-gated tools (web_fetch) see the
# dispatch mode and ctx-aware pack tool bodies can read the triggering context.
# Ported from activegraph tests/test_tools.py ToolContext construction + the
# runtime's `_invoke_tool` wiring (external_io_mode="runtime_recorded").

describe Chronicle::ToolContext do
  it "exposes the narrow tool surface with external_io_mode defaulting to forbid" do
    ctx = Chronicle::ToolContext.new(
      behavior_name: "b", event_id: "evt_1", frame_id: "frame_1",
      idempotency_key: "k", timeout_seconds: 1.0,
    )
    ctx.behavior_name.should eq("b")
    ctx.event_id.should eq("evt_1")
    ctx.frame_id.should eq("frame_1")
    ctx.idempotency_key.should eq("k")
    ctx.timeout_seconds.should eq(1.0)
    ctx.external_io_mode.should eq(Chronicle::ExternalIOMode::Forbid)
  end
end

describe Chronicle::Tool do
  it "threads the context's external_io_mode into mode-gated tools" do
    tool = Chronicle.make_web_fetch_tool
    expect_raises(Chronicle::ToolError) do
      tool.call(
        %({"url":"https://example.test"}),
        Chronicle::ToolContext.new(external_io_mode: Chronicle::ExternalIOMode::RuntimeRecorded),
      )
    end

    fetched = Chronicle.make_web_fetch_tool(fetcher: ->(url : String) { Chronicle::WebFetchOutput.new("ok", 200, url) })
    output = fetched.call(
      %({"url":"https://example.test"}),
      Chronicle::ToolContext.new(external_io_mode: Chronicle::ExternalIOMode::LiveUnrecorded),
    )
    JSON.parse(output).as_h["text"].as_s.should eq("ok")
  end
end

class ToolCtxLoopModel
  include Crig::Completion::CompletionModel

  class_property call_count = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    self.class.call_count += 1
    if self.class.call_count == 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.tool_call("c1", "toolctx.echo_ctx", JSON.parse(%({"q":"1"})))
        ),
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

module ToolCtxPack
  include Chronicle::Packs::DSL

  class_property captured_behavior : String? = nil
  class_property captured_event : String? = nil
  class_property captured_mode : String? = nil
  class_property captured_frame : String? = nil

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["echo_ctx"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
  end

  @[Tool(name: "echo_ctx", description: "capture the tool context")]
  def echo_ctx(args : String, ctx : Chronicle::ToolContext) : String
    ToolCtxPack.captured_behavior = ctx.behavior_name
    ToolCtxPack.captured_event = ctx.event_id
    ToolCtxPack.captured_mode = ctx.external_io_mode.to_s
    ToolCtxPack.captured_frame = ctx.frame_id
    %({"echo":"ok"})
  end

  pack(name: "toolctx", version: "0.1.0")
end

describe "ToolContext runtime threading" do
  it "threads behavior/event/frame/mode into ctx-aware pack tool bodies during LLM dispatch" do
    ToolCtxPack.captured_behavior = nil
    ToolCtxPack.captured_event = nil
    ToolCtxPack.captured_mode = nil
    ToolCtxPack.captured_frame = nil
    ToolCtxLoopModel.call_count = 0

    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    model = ToolCtxLoopModel.new
    agent = Crig::Agent(ToolCtxLoopModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(ToolCtxLoopModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(
      Chronicle::FixedModelExecutor(ToolCtxLoopModel).new(model),
    )
    rt = Chronicle::Runtime(ToolCtxLoopModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
    )
    rt.load_pack(ToolCtxPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    ToolCtxPack.captured_behavior.should eq("toolctx.ex")
    ToolCtxPack.captured_event.should_not be_nil
    ToolCtxPack.captured_mode.should eq("runtime_recorded")
    ToolCtxPack.captured_frame.should be_nil
  end
end
