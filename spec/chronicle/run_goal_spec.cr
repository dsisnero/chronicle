require "../spec_helper"

# `run_goal` — the pack-driven entry point that emits a `goal.created` event
# and runs pack behaviors until the log quiesces, then records an
# idle/budget marker. Ported from activegraph tests/test_runtime.py.

module RunGoalPack
  include Chronicle::Packs::DSL

  class_property fired : Int32 = 0

  @[Behavior(name: "noop", on: ["goal.created"])]
  def noop(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    RunGoalPack.fired += 1
  end

  pack(name: "rungoal", version: "0.1.0")
end

module RunGoalLoopPack
  include Chronicle::Packs::DSL

  class_property ticks : Int32 = 0

  # Re-adds a tick object on every object.created so the dispatch loop keeps
  # producing events until the budget stops it.
  @[Behavior(name: "loop", on: ["object.created"])]
  def loop(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    RunGoalLoopPack.ticks += 1
    graph.add_object("tick", %({"n":1}))
  end

  pack(name: "rungoalloop", version: "0.1.0")
end

module RunGoalSpecHelper
  extend self

  def runtime(budget : Chronicle::Runtime::Budget = Chronicle::Runtime::Budget.new) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, budget: budget)
    {store, graph, rt}
  end
end

private def run_goal_runtime(&)
  store, graph, rt = RunGoalSpecHelper.runtime
  yield store, graph, rt
end

describe Chronicle::Runtime do
  it "run_goal emits goal.created and runs pack behaviors until idle" do
    RunGoalPack.fired = 0
    run_goal_runtime do |store, graph, rt|
      rt.load_pack(RunGoalPack::PACK)
      rt.run_goal("hello")

      RunGoalPack.fired.should eq(1)
      types = store.iter_events.map(&.type)
      types.should contain("goal.created")
      types.last.should eq("runtime.idle")
      goal = store.iter_events.find! { |e| e.type == "goal.created" }
      JSON.parse(goal.payload)["goal"].as_s.should eq("hello")
    end
  end

  it "run_goal accepts a custom actor on the goal event" do
    run_goal_runtime do |store, graph, rt|
      rt.load_pack(RunGoalPack::PACK)
      rt.run_goal("g", actor: "planner")
      goal = store.iter_events.find! { |e| e.type == "goal.created" }
      goal.actor.should eq("planner")
    end
  end

  it "run_goal drives a pack behavior that produces new events until quiescent" do
    run_goal_runtime do |store, graph, rt|
      rt.load_pack(RunGoalPack::PACK)
      rt.run_goal("g")
      # After the idle marker, dispatch is done; no new goal.created re-trigger.
      idle = store.iter_events.to_a.index! { |e| e.type == "runtime.idle" }
      (idle + 1).should eq(store.iter_events.size)
    end
  end

  it "emits runtime.budget_exhausted instead of idle when the budget stops the loop" do
    RunGoalLoopPack.ticks = 0
    store, graph, rt = RunGoalSpecHelper.runtime(budget: Chronicle::Runtime::Budget.new(max_events: 6))
    rt.load_pack(RunGoalLoopPack::PACK)
    graph.add_object("tick", %({"n":0}))
    rt.run_until_idle

    types = store.iter_events.map(&.type)
    types.last.should eq("runtime.budget_exhausted")
    types.should contain("object.created")
    RunGoalLoopPack.ticks.should be > 0
  end
end
