require "../spec_helper"

# `Runtime#diff` — structural comparison of two runs (parent vs fork).
# Ported from activegraph.runtime.diff (CONTRACT v0.5 #10): shared event prefix
# plus each side's tail (lifecycle events filtered), and per-id divergent
# objects/relations via provenance-stripped snapshots. Structural only.

require "file"
require "file_utils"

module DiffPlanPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "planner", on: ["goal.created"])]
  def planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    research = graph.add_object("task", %({"title":"Research: Evaluate","status":"open"}))
    memo = graph.add_object("task", %({"title":"Draft memo","status":"blocked"}))
    graph.add_relation(research.id, memo.id, "depends_on")
  end

  pack(name: "diffplan", version: "0.1.0")
end

private def diff_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_diff_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def diff_agent : Crig::Agent(PackModel)
  Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
end

private def diff_parent(tag : String) : {String, Chronicle::Runtime(PackModel), Chronicle::GraphProjection}
  db = diff_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "diff_parent_#{tag}")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(diff_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
  rt.load_pack(DiffPlanPack::PACK)
  rt.run_goal("Evaluate")
  {db, rt, graph}
end

private def diff_fork_at_tip(parent : Chronicle::Runtime(PackModel)) : Chronicle::Runtime(PackModel)
  parent.fork(at_event: parent.graph.not_nil!.events[-1].id, label: "branch")
end

describe Chronicle::Runtime do
  it "diff of identical runs has no divergence" do
    db, parent, _graph = diff_parent("identical")
    fork = diff_fork_at_tip(parent)

    diff = parent.diff(fork)
    diff.identical?.should be_true
    diff.divergent_objects.should be_empty
    diff.divergent_relations.should be_empty
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "diff is_identical reflects divergent objects" do
    diff = Chronicle::Diff.new(parent_run_id: "parent", fork_run_id: "fork")
    diff.identical?.should be_true

    diff2 = diff.copy_with(divergent_objects: [
      Chronicle::DivergentObject.new(id: "task#1", in_parent: nil, in_fork: nil),
    ])
    diff2.identical?.should be_false
  end

  it "diff reports divergent objects (fork-only and differing)" do
    db, parent, _graph = diff_parent("objects")
    fork = diff_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("claim", %({"text":"counter"}))

    diff = parent.diff(fork)
    fork_only_ids = diff.divergent_objects.select { |d| d.in_parent.nil? }.map(&.id)
    fork_only_ids.should_not be_empty
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "diff partitions events after divergence and filters lifecycle events" do
    db, parent, _graph = diff_parent("partition")
    target = parent.graph.not_nil!.events[1].id
    fork = parent.fork(at_event: target)
    fork.graph.not_nil!.add_object("claim", %({"text":"x"}))

    diff = parent.diff(fork)
    diff.shared_events.should_not be_empty
    all = diff.shared_events + diff.parent_only_events + diff.fork_only_events
    all.each do |event|
      event.type.should_not start_with("behavior.")
      event.type.should_not start_with("relation_behavior.")
      event.type.should_not start_with("runtime.")
    end
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "same logical event id with different payload is not shared" do
    db, parent, _graph = diff_parent("collision")
    target = parent.graph.not_nil!.events[1].id
    fork = parent.fork(at_event: target)
    fork.graph.not_nil!.add_object("decision", %({"text":"branch decision"}))

    diff = parent.diff(fork)
    shared_ids = diff.shared_events.map(&.id).to_set
    fork_only_ids = diff.fork_only_events.map(&.id).to_set
    (shared_ids & fork_only_ids).should be_empty
  ensure
    File.delete(db) if db && File.exists?(db)
  end
end
