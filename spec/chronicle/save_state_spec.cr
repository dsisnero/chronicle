require "../spec_helper"

# `Runtime#save_state` — persist the event log (CONTRACT v0.5 #5). Ported
# from activegraph tests/test_persistence.py:
#   - test_late_bound_save_writes_in_memory_events_to_sqlite
#   - test_save_state_without_store_requires_path
#   - test_save_state_path_must_match_attached_store
#   - test_save_then_load_produces_identical_graph
#
# With a SQLite store already attached, save_state() flushes (no path needed;
# a given path must match the attached store's). Without a durable store it
# late-binds a SQLite store at `path` and appends every in-memory event.

require "file"
require "file_utils"

module SaveStatePack
  include Chronicle::Packs::DSL

  @[Behavior(name: "planner", on: ["goal.created"])]
  def planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    research = graph.add_object("task", %({"title":"Research","status":"open"}))
    memo = graph.add_object("task", %({"title":"Draft memo","status":"blocked"}))
    graph.add_relation(research.id, memo.id, "depends_on")
  end

  pack(name: "savestate", version: "0.1.0")
end

private def save_state_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_save_state_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def save_state_agent : Crig::Agent(PackModel)
  Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
end

# A memory-backed runtime (no durable store), mirroring upstream
# `Runtime(graph)` with no persist_to.
private def memory_runtime(tag : String)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(save_state_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  {store, graph, rt}
end

# A SQLite-backed runtime, mirroring upstream `Runtime(graph, persist_to=db)`.
private def sqlite_runtime(tag : String)
  db = save_state_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "save_#{tag}")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(save_state_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
  {db, store, graph, rt}
end

describe Chronicle::Runtime do
  it "late-binds a SQLite store and persists in-memory events (test_late_bound_save_writes_in_memory_events_to_sqlite)" do
    db = save_state_db_path("late")
    _store, graph, rt = memory_runtime("late")
    rt.load_pack(SaveStatePack::PACK)
    rt.run_goal("Evaluate")
    rt.store.should be_a(Chronicle::MemoryEventStore)

    path = rt.save_state(db)
    path.should eq(db)
    rt.store.should be_a(Chronicle::SQLiteEventStore)

    loaded = Chronicle::Runtime.load(path, run_id: rt.run_id, agent: save_state_agent)
    loaded.store.iter_events.map(&.id).should eq(rt.store.iter_events.map(&.id))
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "requires path when no durable store is attached (test_save_state_without_store_requires_path)" do
    _store, _graph, rt = memory_runtime("nopath")
    rt.run_goal("x")
    expect_raises(Chronicle::InvalidRuntimeConfiguration) { rt.save_state }
  end

  it "rejects a path that does not match the attached store (test_save_state_path_must_match_attached_store)" do
    db, _store, _graph, rt = sqlite_runtime("mismatch")
    rt.run_goal("x")
    other = save_state_db_path("other")
    expect_raises(Chronicle::InvalidRuntimeConfiguration) { rt.save_state(other) }
  ensure
    File.delete(db) if db && File.exists?(db)
    File.delete(other) if other && File.exists?(other)
  end

  it "flushes and returns the attached store path on save_state()" do
    db, _store, _graph, rt = sqlite_runtime("flush")
    rt.run_goal("x")
    rt.save_state.should eq(db)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "save then load reproduces the identical graph (test_save_then_load_produces_identical_graph)" do
    db, store, graph, rt = sqlite_runtime("roundtrip")
    rt.load_pack(SaveStatePack::PACK)
    rt.run_goal("Evaluate this startup idea")
    rt.save_state

    loaded = Chronicle::Runtime.load(db, run_id: rt.run_id, agent: save_state_agent)
    loaded.graph.not_nil!.all_objects.map(&.id).sort.should eq(graph.all_objects.map(&.id).sort)
    loaded.graph.not_nil!.all_relations.map(&.id).sort.should eq(graph.all_relations.map(&.id).sort)
    loaded.store.iter_events.map(&.id).should eq(store.iter_events.map(&.id))
  ensure
    File.delete(db) if db && File.exists?(db)
  end
end
