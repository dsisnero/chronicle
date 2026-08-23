require "../spec_helper"

# Per-call budget dimensions consumed during behavior dispatch (CONTRACT v0.6
# #9/#10): upstream `_invoke`/`_invoke_llm` consume `max_behavior_calls` once
# per behavior invocation and `max_llm_calls` once per LLM behavior invocation
# (runtime.py:1390/1505-1506). When a dimension exhausts mid-run, the dispatch
# loop stops and emits `runtime.budget_exhausted`. Ported from activegraph
# tests/test_llm_budget.py `test_max_llm_calls_dimension_consumed_per_call` +
# the behavior-call consumption upstream does in `_invoke`.

module BudgetCallPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("document", %({"title":"T","body":"B"}))
  end

  @[LLMBehavior(name: "extractor", on: ["object.created"], where: {"type" => "document"})]
  def extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    # no-op handler
  end

  pack(name: "budgetcalls", version: "0.1.0")
end

module BudgetCallModel
  class Scripted
    include Crig::Completion::CompletionModel

    def completion(request : Crig::Completion::Request::CompletionRequest)
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("x")
        ),
        Crig::Completion::Usage.new(input_tokens: 4, output_tokens: 2),
        "raw",
        "msg_budget",
      )
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "not implemented in test"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end
end

private def budget_call_runtime(budget : Chronicle::Budget) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(
    Chronicle::FixedModelExecutor(BudgetCallModel::Scripted).new(BudgetCallModel::Scripted.new),
  )
  rt = Chronicle::Runtime(PackModel).new(
    store: store, log_agent: la, graph: graph, model_effect_worker: worker, budget: budget,
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "consumes max_behavior_calls once per behavior invocation" do
    budget = Chronicle::Budget.new(limits: {"max_events" => 1000.0})
    store, graph, rt = budget_call_runtime(budget)
    rt.load_pack(BudgetCallPack::PACK)
    rt.run_goal("g")

    # seed (plain) + extractor (LLM) each consume one max_behavior_calls unit.
    budget.used["max_behavior_calls"].should eq(2.0)
  end

  it "consumes max_llm_calls once per LLM behavior invocation (test_max_llm_calls_dimension_consumed_per_call)" do
    budget = Chronicle::Budget.new(limits: {"max_events" => 1000.0, "max_llm_calls" => 1.0})
    store, graph, rt = budget_call_runtime(budget)
    rt.load_pack(BudgetCallPack::PACK)
    rt.run_goal("g")

    budget.used["max_llm_calls"].should eq(1.0)
  end

  it "stops the run with a budget_exhausted marker when max_llm_calls is spent" do
    budget = Chronicle::Budget.new(limits: {"max_events" => 1000.0, "max_llm_calls" => 1.0})
    store, graph, rt = budget_call_runtime(budget)
    rt.load_pack(BudgetCallPack::PACK)
    rt.run_goal("g")

    markers = store.iter_events.select { |e| e.type == "runtime.budget_exhausted" }
    markers.should_not be_empty
  end
end
