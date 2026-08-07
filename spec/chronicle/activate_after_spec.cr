require "../spec_helper"

# `activate_after` delayed-queue scheduling (v0.7). Ported from
# activegraph.tests.test_activate_after and the scheduler in
# activegraph.runtime.scheduler. A behavior with `activate_after=N` is not
# invoked when it matches; the runtime emits `behavior.scheduled` and pushes a
# delayed entry that fires N events later. `parse_activate_after` accepts an
# int or "N"/"N event"/"N events" and rejects bool, 0/negative, wall-clock
# units, and unparseable strings.

module ActivateAfterParseSpec
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

private def activate_after_runtime(&)
  store, graph, rt = ActivateAfterParseSpec.runtime
  yield store, graph, rt
end

module ActivateAfterFiresPack
  include Chronicle::Packs::DSL

  class_property fired : Array(String) = [] of String

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("task", %({"title":"t","status":"open"}))
    graph.add_object("noise", %({"i":1}))
    graph.add_object("noise", %({"i":2}))
  end

  @[Behavior(name: "nag", on: ["object.created"], where: {"type" => "task"}, activate_after: 2)]
  def nag(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    id = JSON.parse(event.payload)["id"].as_s
    ActivateAfterFiresPack.fired << id
  end

  pack(name: "activateafterfires", version: "0.1.0")
end

module ActivateAfterSkipsPack
  include Chronicle::Packs::DSL

  class_property fired : Array(String) = [] of String

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("task", %({"title":"t","status":"open"}))
  end

  @[Behavior(name: "closer", on: ["object.created"], where: {"type" => "task"})]
  def closer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    id = JSON.parse(event.payload)["id"].as_s
    graph.patch_object(id, %({"title":"t","status":"closed"}))
  end

  @[Behavior(name: "nag", on: ["object.created"], where: {"type" => "task"}, activate_after: 1)]
  def nag(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    id = JSON.parse(event.payload)["id"].as_s
    obj = graph.get_object(id)
    if obj && JSON.parse(obj.data)["status"].as_s == "open"
      ActivateAfterSkipsPack.fired << id
    end
  end

  pack(name: "activateafterskips", version: "0.1.0")
end

describe Chronicle::Packs do
  describe "parse_activate_after" do
    it "accepts an int" do
      Chronicle::Packs.parse_activate_after(3).should eq(3)
    end

    it "accepts 'N events', 'N event', and 'N'" do
      Chronicle::Packs.parse_activate_after("2 events").should eq(2)
      Chronicle::Packs.parse_activate_after("1 event").should eq(1)
      Chronicle::Packs.parse_activate_after("5").should eq(5)
    end

    it "rejects bool, zero/negative, wall-clock units, and garbage" do
      expect_raises(Chronicle::Packs::InvalidActivateAfter) { Chronicle::Packs.parse_activate_after(true) }
      expect_raises(Chronicle::Packs::InvalidActivateAfter) { Chronicle::Packs.parse_activate_after(0) }
      expect_raises(Chronicle::Packs::InvalidActivateAfter) { Chronicle::Packs.parse_activate_after(-1) }
      expect_raises(Chronicle::Packs::InvalidActivateAfter) { Chronicle::Packs.parse_activate_after("2 minutes") }
      expect_raises(Chronicle::Packs::InvalidActivateAfter) { Chronicle::Packs.parse_activate_after("whenever") }
    end
  end

  describe "activate_after scheduling" do
    it "fires the behavior N events after the trigger and emits behavior.scheduled" do
      ActivateAfterFiresPack.fired = [] of String
      activate_after_runtime do |store, graph, rt|
        rt.load_pack(ActivateAfterFiresPack::PACK)
        rt.run_goal("g")

        ActivateAfterFiresPack.fired.should eq(["task#1"])
        scheduled = store.iter_events.select { |e| e.type == "behavior.scheduled" }
        scheduled.size.should eq(1)
        payload = JSON.parse(scheduled[0].payload)
        payload["behavior"].as_s.should eq("activateafterfires.nag")
        payload["activate_after"].as_i.should eq(2)
      end
    end

    it "re-checks the triggering condition at fire time (closer already ran)" do
      ActivateAfterSkipsPack.fired = [] of String
      activate_after_runtime do |store, graph, rt|
        rt.load_pack(ActivateAfterSkipsPack::PACK)
        rt.run_goal("g")

        ActivateAfterSkipsPack.fired.should eq([] of String)
        scheduled = store.iter_events.select { |e| e.type == "behavior.scheduled" }
        scheduled.size.should eq(1)
      end
    end
  end
end
