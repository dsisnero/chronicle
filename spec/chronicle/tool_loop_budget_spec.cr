require "../spec_helper"

# max_tool_calls budget enforcement in the LLM behavior tool loop. Ported from
# activegraph tests/test_llm_tool_loop.py::test_max_tool_calls_budget_triggers_behavior_failed:
# when the behavior tool loop tries to invoke more tool calls than the
# max_tool_calls budget allows, the behavior fails loud with
# reason="budget.tool_calls_exhausted" and the handler never runs.

class BudgetToolLoopModel
  include Crig::Completion::CompletionModel

  class_property call_count = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    self.class.call_count += 1
    case self.class.call_count
    when 1
      response(tool: "c1", name: "budgettool.my_tool", args: %({"q":"1"}))
    when 2
      response(tool: "c2", name: "budgettool.my_tool", args: %({"q":"2"}))
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

module BudgetToolPack
  include Chronicle::Packs::DSL

  class_property captured_output : String? = nil

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    BudgetToolPack.captured_output = output
  end

  @[Tool(name: "my_tool", description: "t")]
  def my_tool(args : String) : String
    JSON.build do |json|
      json.object do
        json.field "answer", args
      end
    end
  end

  pack(name: "budgettool", version: "0.1.0")
end

private def budget_tool_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BudgetToolLoopModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  model = BudgetToolLoopModel.new
  agent = Crig::Agent(BudgetToolLoopModel).new(model: model, preamble: "")
  la = Chronicle::LogAgent(BudgetToolLoopModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(BudgetToolLoopModel).new(model))
  rt = Chronicle::Runtime(BudgetToolLoopModel).new(
    store: store,
    log_agent: la,
    graph: graph,
    model_effect_worker: worker,
    budget: Chronicle::Budget.new(limits: {"max_tool_calls" => 1.0}),
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "fails loud with reason budget.tool_calls_exhausted when max_tool_calls is exceeded" do
    BudgetToolPack.captured_output = nil
    BudgetToolLoopModel.call_count = 0
    store, graph, rt = budget_tool_runtime
    rt.load_pack(BudgetToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    BudgetToolPack.captured_output.should be_nil
    failures = store.iter_events.select { |e| e.type == "behavior.failed" }
    failures.should_not be_empty
    payloads = failures.map(&.payload)
    payloads.any? { |p| p.includes?("budget.tool_calls_exhausted") }.should be_true
    store.iter_events.count { |e| e.type == "tool.responded" }.should eq(1)
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_false
  end

  it "links the tool.requested that tripped the budget causally" do
    BudgetToolLoopModel.call_count = 0
    store, graph, rt = budget_tool_runtime
    rt.load_pack(BudgetToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    failed = store.iter_events.find { |e| e.type == "behavior.failed" }.not_nil!
    payload = JSON.parse(failed.payload).as_h
    payload["reason"]?.should eq("budget.tool_calls_exhausted")
    payload["tool"]?.should eq("budgettool.my_tool")
  end
end
