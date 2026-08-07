require "../spec_helper"

# `run_until(predicate)` — the predicate-bounded run-loop form. Ported from
# activegraph.runtime.runtime.Runtime#run_until: dispatches pack behaviors
# until the predicate over the graph is satisfied, the log quiesces, or the
# budget stops the loop, then records the idle/budget marker.

module RunUntilLoopPack
  include Chronicle::Packs::DSL

  class_property added : Int32 = 0

  # Re-adds an item on every object.created so the loop keeps producing events
  # until the predicate (or budget) stops it.
  @[Behavior(name: "loop", on: ["object.created"])]
  def loop(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    RunUntilLoopPack.added += 1
    graph.add_object("item", %({"n":1}))
  end

  pack(name: "rununtil", version: "0.1.0")
end

module RunUntilNoopPack
  include Chronicle::Packs::DSL

  class_property fired : Int32 = 0

  @[Behavior(name: "noop", on: ["goal.created"])]
  def noop(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    RunUntilNoopPack.fired += 1
  end

  pack(name: "rununtilnoop", version: "0.1.0")
end

module RunUntilSpecHelper
  extend self

  def runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
    {store, graph, rt}
  end
end

private def run_until_runtime(&)
  store, graph, rt = RunUntilSpecHelper.runtime
  yield store, graph, rt
end

describe Chronicle::Runtime do
  it "run_until stops as soon as the predicate over the graph is satisfied" do
    RunUntilLoopPack.added = 0
    run_until_runtime do |store, graph, rt|
      rt.load_pack(RunUntilLoopPack::PACK)
      graph.add_object("item", %({"n":0}))
      rt.run_until(->(g : Chronicle::GraphProjection) { g.all_objects.size >= 3 })

      graph.all_objects.size.should eq(3)
      types = store.iter_events.map(&.type)
      types.last.should eq("runtime.idle")
    end
  end

  it "run_until quiesces and records idle when the predicate is never satisfied" do
    RunUntilNoopPack.fired = 0
    run_until_runtime do |store, graph, rt|
      rt.load_pack(RunUntilNoopPack::PACK)
      rt.run_until(->(g : Chronicle::GraphProjection) { false })

      RunUntilNoopPack.fired.should eq(0)
      types = store.iter_events.map(&.type)
      types.last.should eq("runtime.idle")
      types.should contain("pack.loaded")
    end
  end

  it "run_until respects the budget and records budget_exhausted" do
    RunUntilLoopPack.added = 0
    store, graph, rt = RunUntilSpecHelper.runtime
    rt.load_pack(RunUntilLoopPack::PACK)
    graph.add_object("item", %({"n":0}))
    rt.run_until(->(g : Chronicle::GraphProjection) { g.all_objects.size >= 100_000 })

    types = store.iter_events.map(&.type)
    types.last.should eq("runtime.budget_exhausted")
  end
end
