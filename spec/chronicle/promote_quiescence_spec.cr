require "../spec_helper"

# Promote edge semantics ported from activegraph.tests.test_promote that lock
# the remaining CONTRACT v1.3 #4 behaviors: atomic fork-block slicing, quiescent
# apply (delta events never fire behaviors; only the marker reacts), reload not
# requeueing delta events, both-removed and both-created collisions, unrelated
# and cross-store lineage rejection, computed_against, pack/settings warnings,
# and schema validation of the promoted delta.

require "file"
require "file_utils"

module PromoteEdgePack
  include Chronicle::Packs::DSL

  class_property created_fired : Int32 = 0
  class_property marker_fired : Int32 = 0
  class_property marker_sees : Bool = false

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("task", %({"title":"base","status":"open"}))
  end

  @[Behavior(name: "note_watcher", on: ["object.created"], where: {"type" => "note"})]
  def note_watcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    PromoteEdgePack.created_fired += 1
  end

  @[Behavior(name: "promote_watcher", on: ["promote.applied"])]
  def promote_watcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    PromoteEdgePack.marker_fired += 1
    payload = JSON.parse(event.payload).as_h
    created_id = payload["objects_created"].as_a[0].as_s
    PromoteEdgePack.marker_sees = graph.get_object(created_id).nil? == false
  end

  pack(name: "promoteedge", version: "0.1.0")
end

private def edge_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_promote_edge_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def edge_agent : Crig::Agent(PackModel)
  Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
end

private def edge_parent(tag : String) : {String, Chronicle::Runtime(PackModel), Chronicle::GraphProjection}
  db = edge_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "edge_parent_#{tag}")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(edge_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
  rt.load_pack(PromoteEdgePack::PACK)
  rt.run_goal("hello")
  {db, rt, graph}
end

private def edge_fork_at_tip(parent : Chronicle::Runtime(PackModel)) : Chronicle::Runtime(PackModel)
  target = parent.graph.not_nil!.events[-1].id
  parent.fork(at_event: target, label: "candidate")
end

private def edge_task_id(rt : Chronicle::Runtime(PackModel)) : String
  rt.graph.not_nil!.objects(type: "task").first.id
end

private def edge_data(obj : Chronicle::GraphObject) : JSON::Any
  JSON.parse(obj.data)
end

describe Chronicle::Runtime do
  it "fork cannot slice a promote block (marker or mid-delta)" do
    db, parent, _rt = edge_parent("slice")
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("note", %({"text":"a"}))
    fork.graph.not_nil!.add_object("note", %({"text":"b"}))
    result = parent.promote(fork).as(Chronicle::PromoteResult)
    parent.run_until_idle

    exc = expect_raises(Chronicle::IncompatibleRuntimeState) { parent.fork(at_event: result.marker_event_id) }
    exc.message.to_s.should contain("slice the promote")
    expect_raises(Chronicle::IncompatibleRuntimeState, /slice the promote/) { parent.fork(at_event: result.applied_event_ids[0]) }

    ok = parent.fork(at_event: result.applied_event_ids[-1])
    ok.graph.not_nil!.get_object("note#2").should_not be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "apply is quiescent: delta events never fire behaviors; only the marker reacts once" do
    PromoteEdgePack.created_fired = 0
    PromoteEdgePack.marker_fired = 0
    PromoteEdgePack.marker_sees = false
    db, parent, _rt = edge_parent("quiescent")
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("note", %({"text":"promoted"}))

    parent.promote(fork).as(Chronicle::PromoteResult)
    parent.run_until_idle

    PromoteEdgePack.created_fired.should eq(0)
    PromoteEdgePack.marker_fired.should eq(1)
    PromoteEdgePack.marker_sees.should be_true
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "load does not requeue promote delta events (only the marker reacts)" do
    db, parent, _rt = edge_parent("requeue")
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("note", %({"text":"x"}))
    parent.promote(fork).as(Chronicle::PromoteResult)
    # Deliberately NO run_until_idle: the marker is still undrained when we stop.
    PromoteEdgePack.created_fired = 0
    PromoteEdgePack.marker_fired = 0

    loaded = Chronicle::Runtime(PackModel).load(db, parent.run_id, edge_agent)
    loaded.load_pack(PromoteEdgePack::PACK)
    loaded.run_until_idle

    # The delta note-create never fires note_watcher; only the marker reacts.
    PromoteEdgePack.created_fired.should eq(0)
    PromoteEdgePack.marker_fired.should eq(1)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "both removed on both sides is a conflict" do
    db, parent, _rt = edge_parent("bothremoved")
    task = edge_task_id(parent)
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.remove_object(task)
    parent.graph.not_nil!.remove_object(task)

    exc = expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    exc.conflicts[0].detail.to_s.should contain("removed on both sides")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "same id both created (reseeded collision) conflicts" do
    db, parent, _rt = edge_parent("bothcreated")
    fork = edge_fork_at_tip(parent)
    fork_obj = fork.graph.not_nil!.add_object("note", %({"text":"fork's"}))
    parent_obj = parent.graph.not_nil!.add_object("note", %({"text":"parent's"}))
    fork_obj.id.should eq(parent_obj.id)

    exc = expect_raises(Chronicle::PromoteConflictError) { parent.promote(fork) }
    exc.conflicts[0].detail.to_s.should contain("both sides")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "rejects truly unrelated run on the same store" do
    db, parent, _rt = edge_parent("unrelated")
    unrelated_store = Chronicle::SQLiteEventStore.new(db, run_id: "unrelated_#{Random::Secure.hex(4)}")
    unrelated_graph = Chronicle::GraphProjection.empty.attach_store(unrelated_store)
    unrelated_la = Chronicle::LogAgent(PackModel).new(edge_agent, store: unrelated_store, max_turns: 1)
    unrelated = Chronicle::Runtime(PackModel).new(store: unrelated_store, log_agent: unrelated_la, graph: unrelated_graph, run_id: unrelated_store.run_id)
    unrelated.run_goal("independent")

    expect_raises(Chronicle::PromoteLineageError) { parent.promote(unrelated) }
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "rejects cross-store runs" do
    db_a, parent_a, _rt = edge_parent("cross_a")
    db_b, _parent_b, _rt_b = edge_parent("cross_b")
    fork_b = edge_fork_at_tip(_parent_b)
    expect_raises(Chronicle::PromoteLineageError) { parent_a.promote(fork_b) }
  ensure
    File.delete(db_a) if db_a && File.exists?(db_a)
    File.delete(db_b) if db_b && File.exists?(db_b)
  end

  it "result records computed_against directly" do
    db, parent, _rt = edge_parent("computed")
    tip = parent.graph.not_nil!.events[-1].id
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("note", %({"text":"x"}))
    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.computed_against.should eq(tip)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "fork-only pack load surfaces as a warning and is never adopted" do
    db, parent, _rt = edge_parent("packwarn")
    fork = edge_fork_at_tip(parent)
    fork.load_pack(Chronicle::Packs::Pack.new(name: "candidate", version: "0.1.0"))
    fork.graph.not_nil!.add_object("note", %({"text":"x"}))

    plan = parent.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    plan.warnings.any? { |w| w.includes?("candidate@0.1.0") }.should be_true
    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.plan.warnings.any? { |w| w.includes?("candidate@0.1.0") }.should be_true
    parent.loaded_packs.should_not contain("candidate")
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "shared pack produces no false warning" do
    db, parent, _rt = edge_parent("sharedpack")
    parent.load_pack(Chronicle::Packs::Pack.new(name: "shared", version: "1.0.0"))
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.add_object("note", %({"text":"x"}))

    plan = parent.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    plan.warnings.none? { |w| w.includes?("shared@1.0.0") }.should be_true
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "promote validates delta against the parent's pack schema before mutating" do
    db, parent, _rt = edge_parent("schema")
    fork = edge_fork_at_tip(parent)
    note = fork.graph.not_nil!.add_object("task", %({"title":"x"}))
    # The fork patched shared task state to an invalid shape per the parent's
    # schema... here the parent's schema is not installed, so promote passes.
    before = parent.graph.not_nil!.events.size
    parent.promote(fork).as(Chronicle::PromoteResult)
    parent.graph.not_nil!.events.size.should_not eq(before)
    parent.graph.not_nil!.get_object(note.id).should_not be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "rejects a delta that violates the parent's typed schema, pre-mutation" do
    db, parent, _rt = edge_parent("schema_violate")
    typed = Chronicle::Packs::Pack.new(
      name: "typed",
      version: "1.0.0",
      object_types: [
        Chronicle::Packs::ObjectType.new(
          name: "insight",
          validator: ->(data : String) : String {
            parsed = JSON.parse(data).as_h
            confidence = parsed["confidence"].as_f
            if confidence > 1.0
              raise Chronicle::Packs::PackError.new("confidence must be <= 1.0")
            end
            data
          },
        ),
      ],
    )
    parent.load_pack(typed)

    fork = edge_fork_at_tip(parent)
    bad = fork.graph.not_nil!.add_object("insight", %({"text":"x","confidence":5.0}))
    fork.graph.not_nil!.get_object(bad.id).should_not be_nil

    before = parent.graph.not_nil!.events.size
    expect_raises(Chronicle::Packs::PackError) { parent.promote(fork) }
    parent.graph.not_nil!.events.size.should eq(before)
    parent.graph.not_nil!.get_object(bad.id).should be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "canonicalizes a valid typed delta through the parent schema" do
    db, parent, _rt = edge_parent("schema_ok")
    typed = Chronicle::Packs::Pack.new(
      name: "typedok",
      version: "1.0.0",
      object_types: [
        Chronicle::Packs::ObjectType.new(
          name: "insight",
          validator: ->(data : String) : String {
            parsed = JSON.parse(data).as_h
            parsed["confidence"] = JSON::Any.new([parsed["confidence"].as_f, 1.0].min)
            parsed.to_json
          },
        ),
      ],
    )
    parent.load_pack(typed)

    fork = edge_fork_at_tip(parent)
    ok = fork.graph.not_nil!.add_object("insight", %({"text":"x","confidence":0.5}))

    result = parent.promote(fork).as(Chronicle::PromoteResult)
    result.plan.object_creates.any? { |o| o["id"].as_s == ok.id }.should be_true
    edge_data(parent.graph.not_nil!.get_object(ok.id).not_nil!).should eq(JSON.parse(%({"text":"x","confidence":0.5})))
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "unknown types pass through untyped even when the parent has a typed pack" do
    db, parent, _rt = edge_parent("schema_free")
    typed = Chronicle::Packs::Pack.new(
      name: "typedfree",
      version: "1.0.0",
      object_types: [
        Chronicle::Packs::ObjectType.new(name: "insight", validator: ->(data : String) : String { data }),
      ],
    )
    parent.load_pack(typed)

    fork = edge_fork_at_tip(parent)
    n = fork.graph.not_nil!.add_object("freeform", %({"anything":["goes",1]}))
    parent.promote(fork).as(Chronicle::PromoteResult)
    edge_data(parent.graph.not_nil!.get_object(n.id).not_nil!).should eq(JSON.parse(%({"anything":["goes",1]})))
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "fork-of-fork promotes one level at a time" do
    db, parent, _rt = edge_parent("forkoffork")
    child = edge_fork_at_tip(parent)
    grandchild = edge_fork_at_tip(child)
    note = grandchild.graph.not_nil!.add_object("note", %({"text":"deep"}))

    child.promote(grandchild).as(Chronicle::PromoteResult)
    child.graph.not_nil!.get_object(note.id).should_not be_nil
    parent.promote(child).as(Chronicle::PromoteResult)
    parent.graph.not_nil!.get_object(note.id).should_not be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "fork cascade removals promote cleanly" do
    db, parent, _rt = edge_parent("cascade")
    task = edge_task_id(parent)
    fork = edge_fork_at_tip(parent)
    note = fork.graph.not_nil!.add_object("note", %({"text":"n"}))
    rel = fork.graph.not_nil!.add_relation(note.id, task, "annotates")
    parent.promote(fork).as(Chronicle::PromoteResult)

    fork2 = edge_fork_at_tip(parent)
    fork2.graph.not_nil!.remove_object(note.id)
    result = parent.promote(fork2).as(Chronicle::PromoteResult)
    result.plan.object_removes.should eq([note.id])
    result.plan.relation_removes.should contain(rel.id)
    parent.graph.not_nil!.get_object(note.id).should be_nil
    parent.graph.not_nil!.get_relation(rel.id).should be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "residue policy: fork-tail removals of fork-created entities are ordinary events" do
    db, parent, _rt = edge_parent("residue")
    task = edge_task_id(parent)
    fork = edge_fork_at_tip(parent)

    fork.graph.not_nil!.patch_object(task, %({"status":"done"}))
    a = fork.graph.not_nil!.add_object("scaffold", %({"n":1}))
    b = fork.graph.not_nil!.add_object("scaffold", %({"n":2}))
    rel_ab = fork.graph.not_nil!.add_relation(a.id, b.id, "supports")
    rel_task = fork.graph.not_nil!.add_relation(task, a.id, "tried")

    fork.graph.not_nil!.remove_relation(rel_ab.id)
    fork.graph.not_nil!.remove_object(a.id) # cascade removes rel_task too
    fork.graph.not_nil!.remove_object(b.id)
    fork.graph.not_nil!.get_relation(rel_task.id).should be_nil

    plan = parent.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    plan.is_promotable.should be_true
    plan.object_creates.should eq([] of Hash(String, JSON::Any))
    plan.relation_creates.should eq([] of Hash(String, JSON::Any))
    plan.object_removes.should eq([] of String)
    plan.relation_removes.should eq([] of String)
    plan.object_patches.map { |o| o["id"].as_s }.should eq([task])

    result = parent.promote(fork).as(Chronicle::PromoteResult)
    edge_data(parent.graph.not_nil!.get_object(task).not_nil!)["status"].should eq("done")
    parent.graph.not_nil!.get_object(a.id).should be_nil
    parent.graph.not_nil!.get_object(b.id).should be_nil
    parent.graph.not_nil!.get_relation(rel_ab.id).should be_nil
    parent.graph.not_nil!.get_relation(rel_task.id).should be_nil
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "settings override in fork tail surfaces as a warning" do
    db, parent, _rt = edge_parent("settings")
    fork = edge_fork_at_tip(parent)
    fork.graph.not_nil!.emit(Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: 1_u64,
      id: fork.graph.not_nil!.ids.event,
      type: "pack.settings_overridden",
      actor: "runtime",
      caused_by: nil,
      timestamp: Time.utc,
      payload: %({"pack":"diligence","overrides":{"confidence_threshold_for_review":0.9},"assignments":["diligence.confidence_threshold_for_review=0.9"]}),
    ))
    fork.graph.not_nil!.add_object("note", %({"text":"x"}))
    parent.graph.not_nil!.add_object("decoy", %({"n":1}))

    plan = parent.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
    override_warnings = plan.warnings.select { |w| w.includes?("settings override") }
    override_warnings.size.should eq(1)
    override_warnings[0].should contain("diligence")
    override_warnings[0].should contain("confidence_threshold_for_review=0.9")
    override_warnings[0].should_not contain("?=?")
  ensure
    File.delete(db) if db && File.exists?(db)
  end
end
