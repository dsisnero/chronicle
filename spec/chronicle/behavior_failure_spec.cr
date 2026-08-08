require "../spec_helper"

module BehaviorFailureSpecPacks
  module BoomPack
    include Chronicle::Packs::DSL

    class_property fired = 0

    @[Behavior(name: "boom", on: ["goal.created"])]
    def boom(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      BoomPack.fired += 1
      raise "kaboom"
    end

    @[Behavior(name: "ok", on: ["goal.created"])]
    def ok(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      BoomPack.fired += 1
    end

    pack(name: "boomfail", version: "0.1.0")
  end
end

private def behavior_failure_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  {store, graph, rt}
end

describe Chronicle::BehaviorFailure do
  it "is a value struct with the five operational fields plus the failed event id" do
    failure = Chronicle::BehaviorFailure.new(
      behavior: "boom",
      event_id: "goal_created_1",
      reason: nil,
      exception_type: "Exception",
      message: "kaboom",
      failed_event_id: "behavior_failed_2",
    )
    failure.behavior.should eq("boom")
    failure.event_id.should eq("goal_created_1")
    failure.reason.should be_nil
    failure.exception_type.should eq("Exception")
    failure.message.should eq("kaboom")
    failure.failed_event_id.should eq("behavior_failed_2")
  end
end

describe Chronicle::Runtime do
  it "Runtime#errors returns a structured view of behavior.failed events" do
    store, graph, rt = behavior_failure_runtime
    BehaviorFailureSpecPacks::BoomPack.fired = 0
    rt.load_pack(BehaviorFailureSpecPacks::BoomPack::PACK)
    rt.run_goal("trigger")

    errs = rt.errors
    errs.size.should eq(1)
    err = errs.first
    err.behavior.should eq("boomfail.boom")
    err.exception_type.should eq("Exception")
    err.message.should eq("kaboom")
    err.reason.should be_nil

    failed = store.iter_events.find { |e| e.type == "behavior.failed" }.not_nil!
    err.failed_event_id.should eq(failed.id)
  end

  it "Runtime#errors is empty on a clean run" do
    store, graph, rt = behavior_failure_runtime
    rt.run_goal("ok")

    rt.errors.should be_empty
  end

  it "Runtime#errors accumulates multiple failures" do
    store, graph, rt = behavior_failure_runtime
    rt.load_pack(BehaviorFailureSpecPacks::BoomPack::PACK)
    rt.run_goal("trigger")
    rt.run_goal("trigger")

    by_behavior = rt.errors.to_h { |e| {e.behavior, e} }
    by_behavior.keys.sort.should eq(["boomfail.boom"])
    by_behavior["boomfail.boom"].exception_type.should eq("Exception")
  end
end
