require "../spec_helper"

# `Runtime#fork` / `SQLiteEventStore` run forking. Ported from
# activegraph.tests.test_fork (CONTRACT v0.5 #9, #12): branching copies the
# parent's log up to and including `at_event` into a fresh run_id, records run
# lineage, replays into a new graph, and runs independently. Forks-of-forks
# work the same way, and ids resume the fork's own counter (not the parent's).

require "file"
require "file_utils"

module ForkScenarioPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "planner", on: ["goal.created"])]
  def planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    research = graph.add_object("task", %({"title":"r","status":"open"}))
    memo = graph.add_object("task", %({"title":"m","status":"blocked"}))
    graph.add_relation(research.id, memo.id, "depends_on")
  end

  pack(name: "forkscenario", version: "0.1.0")
end

private def fork_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_fork_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def fork_agent : Crig::Agent(PackModel)
  Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
end

private def build_parent(tag : String) : {String, Chronicle::SQLiteEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  db = fork_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent_#{tag}")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(fork_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
  rt.load_pack(ForkScenarioPack::PACK)
  {db, store, graph, rt}
end

describe Chronicle::Runtime do
  it "fork creates a new run with copied events and records lineage" do
    db, _store, graph, parent = build_parent("lineage")
    parent.run_goal("Evaluate")

    target = graph.events[2].id
    fork = parent.fork(at_event: target, label: "branch-A")
    fork.run_id.should_not eq(parent.run_id)

    runs = Chronicle::SQLiteEventStore.list_runs(db).to_h { |r| {r.run_id, r} }
    runs[fork.run_id].parent_run_id.should eq(parent.run_id)
    runs[fork.run_id].forked_at_event_id.should eq(target)
    runs[fork.run_id].label.should eq("branch-A")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "fork leaves the parent untouched and runs independently" do
    db, _store, graph, rt = build_parent("independent")
    rt.run_goal("Evaluate")
    parent_objects_before = graph.all_objects.map(&.id).sort
    parent_events_before = graph.events.map(&.id)

    target = graph.events[2].id
    fork = rt.fork(at_event: target)
    fork.graph.not_nil!.add_object("note", %({"text":"counter"}))

    graph.all_objects.map(&.id).sort.should eq(parent_objects_before)
    graph.events.map(&.id).should eq(parent_events_before)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "forks-of-forks lineage" do
    db, _store, graph, rt = build_parent("of_fork")
    rt.run_goal("Evaluate")

    mid = graph.events[2].id
    fork = rt.fork(at_event: mid, label: "A")
    grandchild = fork.fork(at_event: fork.graph.not_nil!.events[1].id, label: "B")

    runs = Chronicle::SQLiteEventStore.list_runs(db).to_h { |r| {r.run_id, r} }
    runs[grandchild.run_id].parent_run_id.should eq(fork.run_id)
    runs[fork.run_id].parent_run_id.should eq(rt.run_id)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "fork requires a SQLite-backed runtime" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    la = Chronicle::LogAgent(PackModel).new(fork_agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
    expect_raises(Chronicle::IncompatibleRuntimeState) { rt.fork(at_event: "evt_001") }
  end

  it "fork at an unknown event raises" do
    db, _store, _graph, rt = build_parent("unknown")
    rt.run_goal("x")
    expect_raises(Chronicle::EventNotFoundError) { rt.fork(at_event: "evt_999") }
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "fork preserves id counters and lets two forks diverge" do
    db, _store, graph, rt = build_parent("ids")
    rt.run_goal("Evaluate")

    target = graph.events[2].id
    fork_a = rt.fork(at_event: target, label: "A")
    fork_b = rt.fork(at_event: target, label: "B")
    a_obj = fork_a.graph.not_nil!.add_object("note", %({"text":"alpha"}))
    b_obj = fork_b.graph.not_nil!.add_object("note", %({"text":"beta"}))

    a_obj.id.should eq(b_obj.id)
  ensure
    File.delete(db) if db && File.exists?(db)
  end
end
