require "../spec_helper"

# `Runtime#promote` — apply a fork's net structural delta to its parent.
# Ported from activegraph.tests.test_promote (CONTRACT v1.3 #4): three-way
# base/parent/fork comparison, fail-closed atomic conflicts, referential
# integrity, dry-run planning, quiescent apply behind a `promote.applied`
# marker, strict lineage, and actor/cause audit.

require "file"
require "file_utils"

module PromoteSeedPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("task", %({"title":"base","status":"open"}))
  end

  pack(name: "promoteseed", version: "0.1.0")
end

private def promote_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_promote_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def promote_agent : Crig::Agent(PackModel)
  Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
end

# Parent runtime seeded (via `seed`) with one task object, saved to SQLite.
private def promote_parent(tag : String) : {String, Chronicle::Runtime(PackModel), Chronicle::GraphProjection}
  db = promote_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent_#{tag}")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(promote_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
  rt.load_pack(PromoteSeedPack::PACK)
  rt.run_goal("hello")
  {db, rt, graph}
end

# Fork the parent at its current log tip.
private def promote_fork_at_tip(parent : Chronicle::Runtime(PackModel)) : Chronicle::Runtime(PackModel)
  target = parent.graph.not_nil!.events[-1].id
  parent.fork(at_event: target, label: "candidate")
end

private def promote_task_id(rt : Chronicle::Runtime(PackModel)) : String
  rt.graph.not_nil!.objects(type: "task").first.id
end

private def promote_data(obj : Chronicle::GraphObject) : JSON::Any
  JSON.parse(obj.data)
end

describe Chronicle::Runtime do
  it "promote creates objects and relations with their fork ids and state" do
    db, parent, _graph = promote_parent("creates")
    fork = promote_fork_at_tip(parent)
    a = fork.graph.not_nil!.add_object("note", %({"text":"from the fork"}))
    b = fork.graph.not_nil!.add_object("note", %({"text":"second"}))
    rel = fork.graph.not_nil!.add_relation(a.id, b.id, "references")

    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.should be_a(Chronicle::PromoteResult)
    ids = result.plan.object_creates.map { |o| o["id"] }
    ids.should eq([a.id, b.id].sort)
    result.plan.relation_creates.map { |r| r["id"] }.should eq([rel.id])

    promoted = parent.graph.not_nil!.get_object(a.id)
    promoted.should_not be_nil
    promote_data(promoted.not_nil!).should eq(JSON.parse(%({"text":"from the fork"})))
    got_rel = parent.graph.not_nil!.get_relation(rel.id)
    got_rel.should_not be_nil
    {got_rel.not_nil!.from_id, got_rel.not_nil!.to_id}.should eq({a.id, b.id})
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promote patches a shared object to its fork state" do
    db, parent, _rt = promote_parent("patch")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    fork.graph.not_nil!.patch_object(task, %({"status":"done","confidence":0.9}))

    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.plan.object_patches.map { |o| o["id"] }.should eq([task])
    obj = parent.graph.not_nil!.get_object(task).not_nil!
    promote_data(obj).should eq(JSON.parse(%({"title":"base","status":"done","confidence":0.9})))
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promote removes an object removed in the fork" do
    db, parent, _rt = promote_parent("remove")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    fork.graph.not_nil!.remove_object(task)

    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.plan.object_removes.should eq([task])
    parent.graph.not_nil!.get_object(task).should be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promote of an empty delta still emits a marker" do
    db, parent, _rt = promote_parent("empty")
    fork = promote_fork_at_tip(parent)

    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.plan.is_empty.should be_true
    result.applied_event_ids.should eq([] of String)
    marker = parent.graph.not_nil!.events.find { |e| e.type == "promote.applied" }.not_nil!
    marker.id.should eq(result.marker_event_id)
    JSON.parse(marker.payload)["from_run"].as_s.should eq(fork.run_id)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promoted ids do not collide with future parent mints" do
    db, parent, _rt = promote_parent("ids")
    fork = promote_fork_at_tip(parent)
    promoted = fork.graph.not_nil!.add_object("note", %({"text":"x"}))
    parent.promote(fork)
    fresh = parent.graph.not_nil!.add_object("note", %({"text":"own"}))
    fresh.id.should_not eq(promoted.id)
    promote_data(parent.graph.not_nil!.get_object(promoted.id).not_nil!).should eq(JSON.parse(%({"text":"x"})))
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "dry run returns a plan and mutates nothing" do
    db, parent, _rt = promote_parent("dry")
    fork = promote_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("note", %({"text":"x"}))

    before = parent.graph.not_nil!.events.size
    plan = parent.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    plan.is_promotable.should be_true
    plan.object_creates.size.should eq(1)
    parent.graph.not_nil!.events.size.should eq(before)
    plan.computed_against.should eq(parent.graph.not_nil!.events[-1].id)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "both-side patches conflict and fail closed" do
    db, parent, _rt = promote_parent("conflict")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    fork.graph.not_nil!.patch_object(task, %({"status":"done"}))
    parent.graph.not_nil!.patch_object(task, %({"status":"cancelled"}))

    exc = expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    exc.conflicts[0].kind.should eq("both_changed")
    exc.conflicts[0].id.should eq(task)
    promote_data(parent.graph.not_nil!.get_object(task).not_nil!)["status"].should eq("cancelled")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "identical concurrent edits still conflict" do
    db, parent, _rt = promote_parent("identical")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    fork.graph.not_nil!.patch_object(task, %({"status":"done"}))
    parent.graph.not_nil!.patch_object(task, %({"status":"done"}))

    exc = expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    exc.conflicts[0].kind.should eq("both_changed")
    exc.conflicts[0].detail.to_s.should contain("identically")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "atomicity: a conflict blocks the clean parts too" do
    db, parent, _rt = promote_parent("atomic")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    clean = fork.graph.not_nil!.add_object("note", %({"text":"clean create"}))
    fork.graph.not_nil!.patch_object(task, %({"status":"done"}))
    parent.graph.not_nil!.patch_object(task, %({"status":"cancelled"}))

    before = parent.graph.not_nil!.events.size
    expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    parent.graph.not_nil!.events.size.should eq(before)
    parent.graph.not_nil!.get_object(clean.id).should be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "dangling relation to a parent-removed object conflicts" do
    db, parent, _rt = promote_parent("dangling")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    note = fork.graph.not_nil!.add_object("note", %({"text":"n"}))
    fork.graph.not_nil!.add_relation(note.id, task, "annotates")
    parent.graph.not_nil!.remove_object(task)

    exc = expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    exc.conflicts.map(&.kind).should contain("dangling_relation")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "orphaning removal conflicts" do
    db, parent, _rt = promote_parent("orphan")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    fork.graph.not_nil!.remove_object(task)
    other = parent.graph.not_nil!.add_object("note", %({"text":"depends on task"}))
    parent.graph.not_nil!.add_relation(other.id, task, "annotates")

    exc = expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    exc.conflicts.map(&.kind).should contain("orphaning_removal")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "rejects reversed lineage" do
    db, parent, _rt = promote_parent("rev")
    fork = promote_fork_at_tip(parent)
    expect_raises(Chronicle::PromoteLineageError) { fork.promote(parent) }
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "rejects a grandchild (one level at a time)" do
    db, parent, _rt = promote_parent("gc")
    child = promote_fork_at_tip(parent)
    grandchild = promote_fork_at_tip(child)
    grandchild.graph.not_nil!.add_object("note", %({"text":"deep"}))
    expect_raises(Chronicle::PromoteLineageError) { parent.promote(grandchild) }
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promote requires a SQLite-backed runtime" do
    mem = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(mem)
    la = Chronicle::LogAgent(PackModel).new(promote_agent, store: mem, max_turns: 1)
    bare = Chronicle::Runtime(PackModel).new(store: mem, log_agent: la, graph: graph)
    db, parent, _rt = promote_parent("sqlite")
    fork = promote_fork_at_tip(parent)
    expect_raises(Chronicle::IncompatibleRuntimeState) { bare.promote(fork) }
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promoted events carry promote actor and cause, and the marker is causal" do
    db, parent, _rt = promote_parent("audit")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    note = fork.graph.not_nil!.add_object("note", %({"text":"x"}))
    result = parent.promote(fork).as(Chronicle::PromoteResult)

    delta = parent.graph.not_nil!.events.select { |e| result.applied_event_ids.includes?(e.id) }
    delta.should_not be_empty
    delta.each do |e|
      e.actor.should eq("promote:#{fork.run_id}")
      e.caused_by.should eq(result.marker_event_id)
    end
    chain = Chronicle::Trace.causal_chain(parent.graph.not_nil!.events, parent.graph.not_nil!, note.id)
    chain.should contain(result.marker_event_id)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promote survives reload and replay" do
    db, parent, _rt = promote_parent("reload")
    task = promote_task_id(parent)
    fork = promote_fork_at_tip(parent)
    note = fork.graph.not_nil!.add_object("note", %({"text":"x"}))
    fork.graph.not_nil!.patch_object(task, %({"status":"done"}))
    parent.promote(fork)
    parent.run_until_idle

    loaded = Chronicle::Runtime(PackModel).load(db, parent.run_id, promote_agent)
    promote_data(loaded.graph.not_nil!.get_object(note.id).not_nil!).should eq(JSON.parse(%({"text":"x"})))
    promote_data(loaded.graph.not_nil!.get_object(task).not_nil!)["status"].should eq("done")
  ensure
    File.delete(db) if db && File.exists?(db)
  end
end
