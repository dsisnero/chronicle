require "../spec_helper"
require "./status_spec"

# RuntimeStatus state derivation beyond the idle/stopped basics (CONTRACT v0.8
# #11, upstream test_runtime_status.py): an exhausted run reports `exhausted`
# (from the runtime.budget_exhausted marker), and state survives the
# save/load round trip — a freshly loaded runtime sees the same state as the
# runtime that saved.

describe Chronicle::Runtime do
  it "reports state exhausted when the budget trips (test_exhausted_state_on_budget)" do
    rt = status_runtime_with_budget(Chronicle::Budget.new(limits: {"max_behavior_calls" => 0.0}))
    rt.run_goal("x")
    rt.status.state.should eq(Chronicle::RuntimeState::Exhausted)
  end

  it "reports state idle after a clean run to completion (test_idle_state_after_run_to_completion)" do
    rt = status_runtime_with_budget(Chronicle::Budget.new(max_events: 1000_i64))
    rt.run_goal("x")
    rt.status.state.should eq(Chronicle::RuntimeState::Idle)
  end

  it "state survives the save/load round trip (test_state_survives_save_load_round_trip)" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(StatusMockModel).new(model: StatusMockModel.new, preamble: "")
    la = Chronicle::LogAgent(StatusMockModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(StatusMockModel).new(
      store: store, log_agent: la, graph: graph,
      budget: Chronicle::Budget.new(limits: {"max_behavior_calls" => 0.0}),
    )
    rt.load_pack(StatusPack::PACK)
    rt.run_goal("x")
    in_proc_state = rt.status.state
    in_proc_state.should eq(Chronicle::RuntimeState::Exhausted)

    # A fresh runtime over the same store derives the same log-based state.
    agent2 = Crig::Agent(StatusMockModel).new(model: StatusMockModel.new, preamble: "")
    la2 = Chronicle::LogAgent(StatusMockModel).new(agent2, store: store, max_turns: 1)
    rt2 = Chronicle::Runtime(StatusMockModel).new(store: store, log_agent: la2, graph: graph)
    rt2.status.state.should eq(in_proc_state)
  end
end

private def status_runtime_with_budget(budget : Chronicle::Budget) : Chronicle::Runtime(StatusMockModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(StatusMockModel).new(model: StatusMockModel.new, preamble: "")
  la = Chronicle::LogAgent(StatusMockModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(StatusMockModel).new(store: store, log_agent: la, graph: graph, budget: budget)
  rt.load_pack(StatusPack::PACK)
  rt
end
