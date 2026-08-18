require "../spec_helper"

# Compaction and retention pin set (upstream store/retention.py, CONTRACT
# v1.5 #2 phase 1): the reasons a run cannot be compacted or retired. The pin
# set dominates retention policy unconditionally — promoted-from fork logs
# survive every retention operation. Ported from activegraph
# store/retention.py `pins` / `state_hash_of` / RetentionPinnedError.

require "file"
require "file_utils"

private def retention_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_retention_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def retention_event(id : String, type : String, caused_by : String? = nil, payload : String = %({})) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: id,
    type: type, actor: "test", caused_by: caused_by,
    timestamp: Time.utc, payload: payload,
  )
end

describe Chronicle::Retention do
  describe ".state_hash_of" do
    it "returns a sha256: prefixed digest over the canonical blob" do
      hash = Chronicle::Retention.state_hash_of(%({"a":1}))
      hash.starts_with?("sha256:").should be_true
      hash.size.should eq("sha256:".size + 64)
    end
  end

  describe ".pins" do
    it "returns no pins for an unpinned single run" do
      db = retention_db_path("none")
      store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      store.append(retention_event("goal", "goal.created"))
      store.append(retention_event("obj", "object.created"))

      Chronicle::Retention.pins(db, "parent").should be_empty
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    it "pins a run another run promoted from (promoted-from marker)" do
      db = retention_db_path("promote")
      parent = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      parent.append(retention_event("goal", "goal.created"))
      child = Chronicle::SQLiteEventStore.new(db, run_id: "child")
      child.append(retention_event("promote", "promote.applied", nil, %({"from_run":"parent"})))

      reasons = Chronicle::Retention.pins(db, "parent")
      reasons.any? { |reason| reason.starts_with?("promoted-from:") }.should be_true
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    it "pins a run with a live child (live-lineage)" do
      db = retention_db_path("lineage")
      parent = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      parent.append(retention_event("goal", "goal.created"))
      child = Chronicle::SQLiteEventStore.new(db, run_id: "child")
      child.upsert_run(created_at: Time.utc.to_rfc3339, parent_run_id: "parent")
      child.append(retention_event("c1", "object.created"))

      reasons = Chronicle::Retention.pins(db, "parent")
      reasons.any? { |reason| reason.starts_with?("live-lineage:") }.should be_true
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    it "pins a run with unresolved approvals and proposed patches (pending machinery)" do
      db = retention_db_path("pending")
      store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      store.append(retention_event("p1", "approval.proposed", nil, %({"approval_id":"approval_001"})))
      store.append(retention_event("p2", "patch.proposed", nil, %({"patch":{"id":"patch_001"}})))

      reasons = Chronicle::Retention.pins(db, "parent")
      reasons.any? { |reason| reason.starts_with?("pending-approvals:") }.should be_true
      reasons.any? { |reason| reason.starts_with?("proposed-patches:") }.should be_true
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    it "does not pin a run whose approval was granted and patch was applied" do
      db = retention_db_path("resolved")
      store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      store.append(retention_event("p1", "approval.proposed", nil, %({"approval_id":"approval_001"})))
      store.append(retention_event("g1", "approval.granted", nil, %({"approval_id":"approval_001"})))
      store.append(retention_event("p2", "patch.proposed", nil, %({"patch":{"id":"patch_001"}})))
      store.append(retention_event("a1", "patch.applied", nil, %({"patch":{"id":"patch_001"}})))

      Chronicle::Retention.pins(db, "parent").should be_empty
    ensure
      File.delete(db) if db && File.exists?(db)
    end
  end

  describe "archive + snapshot tier" do
    it "round-trips snapshot blobs by state hash" do
      db = retention_db_path("snapshot")
      store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      store.put_snapshot("sha256:abc", %({"objects":[]}), created_at: "2026-01-01T00:00:00Z")
      store.get_snapshot("sha256:abc").should eq(%({"objects":[]}))
      store.get_snapshot("sha256:missing").should be_nil
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    it "archives a prefix and iterates the archived events in order" do
      db = retention_db_path("prefix")
      store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      store.append(retention_event("e1", "goal.created"))
      store.append(retention_event("e2", "object.created"))
      store.append(retention_event("e3", "object.created"))

      moved = store.archive_prefix(3_i64, archived_at: "2026-01-01T00:00:00Z")
      moved.should eq(2)
      store.has_archived.should be_true
      store.iter_archived.map(&.id).should eq(["e1", "e2"])
      store.iter_events.map(&.id).should eq(["e3"])

      # Idempotent: re-running moves nothing.
      store.archive_prefix(3_i64, archived_at: "2026-01-01T00:00:00Z").should eq(0)
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    it "resolves the seq of an event id" do
      db = retention_db_path("seq")
      store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
      store.append(retention_event("e1", "goal.created"))
      store.seq_of("e1").should eq(1_i64)
      expect_raises(Chronicle::EventNotFoundError) { store.seq_of("missing") }
    ensure
      File.delete(db) if db && File.exists?(db)
    end

    describe ".retire" do
      it "archives an entire unpinned run and returns rows moved" do
        db = retention_db_path("retire")
        store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        store.append(retention_event("e1", "goal.created"))
        store.append(retention_event("e2", "object.created"))

        moved = Chronicle::Retention.retire(db, "parent")
        moved.should eq(2)
        store.has_archived.should be_true
        store.iter_events.empty?.should be_true
        store.iter_archived.map(&.id).should eq(["e1", "e2"])
      ensure
        File.delete(db) if db && File.exists?(db)
      end

      it "refuses a pinned run with RetentionPinnedError" do
        db = retention_db_path("retire_pinned")
        parent = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        parent.append(retention_event("e1", "goal.created"))
        child = Chronicle::SQLiteEventStore.new(db, run_id: "child")
        child.upsert_run(created_at: Time.utc.to_rfc3339, parent_run_id: "parent")
        child.append(retention_event("c1", "object.created"))

        error = expect_raises(Chronicle::Retention::RetentionPinnedError) do
          Chronicle::Retention.retire(db, "parent")
        end
        error.reasons.any? { |reason| reason.starts_with?("live-lineage:") }.should be_true
      ensure
        File.delete(db) if db && File.exists?(db)
      end
    end

    describe ".compact" do
      it "snapshots a run and archives its prefix (hot log is snapshot-only)" do
        db = retention_db_path("compact")
        store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        graph = Chronicle::GraphProjection.empty.attach_store(store)
        graph.add_object("task", %({"title":"a"}))
        graph.add_object("task", %({"title":"b"}))

        snapshot_id = Chronicle::Retention.compact(db, "parent")
        hot = store.iter_events
        hot.map(&.type).should eq(["runtime.snapshot"])
        hot[0].id.should eq(snapshot_id)
        store.has_archived.should be_true
        JSON.parse(hot[0].payload).as_h["state_hash"].as_s.starts_with?("sha256:").should be_true
      ensure
        File.delete(db) if db && File.exists?(db)
      end

      it "refuses a pinned run with RetentionPinnedError" do
        db = retention_db_path("compact_pinned")
        parent = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        parent.append(retention_event("e1", "goal.created"))
        child = Chronicle::SQLiteEventStore.new(db, run_id: "child")
        child.upsert_run(created_at: Time.utc.to_rfc3339, parent_run_id: "parent")
        child.append(retention_event("c1", "object.created"))

        expect_raises(Chronicle::Retention::RetentionPinnedError) do
          Chronicle::Retention.compact(db, "parent")
        end
      ensure
        File.delete(db) if db && File.exists?(db)
      end
    end

    describe ".verify_snapshot" do
      it "replays the archived prefix and proves it reproduces the snapshot" do
        db = retention_db_path("verify")
        store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        graph = Chronicle::GraphProjection.empty.attach_store(store)
        graph.add_object("task", %({"title":"a"}))
        graph.add_object("task", %({"title":"b"}))

        Chronicle::Retention.compact(db, "parent")
        Chronicle::Retention.verify_snapshot(db, "parent").should be_true
      ensure
        File.delete(db) if db && File.exists?(db)
      end

      it "raises a LookupError when the run has no snapshot" do
        db = retention_db_path("verify_missing")
        store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        store.append(retention_event("e1", "goal.created"))

        expect_raises(Exception) { Chronicle::Retention.verify_snapshot(db, "parent") }
      ensure
        File.delete(db) if db && File.exists?(db)
      end
    end

    describe "Runtime.load snapshot reconstruction" do
      it "loads a compacted run from its snapshot blob and matches the pre-compact state" do
        db = retention_db_path("load")
        store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
        graph = Chronicle::GraphProjection.empty.attach_store(store)
        graph.add_object("task", %({"title":"a"}))
        graph.add_object("task", %({"title":"b"}))
        graph.add_relation("task#1", "task#2", "depends_on")
        objects_before = graph.all_objects.to_h { |obj| {obj.id, obj.data} }
        relations_before = graph.all_relations.to_h { |rel| {rel.id, rel.type} }

        Chronicle::Retention.compact(db, "parent")

        loaded = Chronicle::Runtime(PackModel).load(
          db, run_id: "parent", agent: Crig::Agent(PackModel).new(model: PackModel.new, preamble: ""))
        loaded_graph = loaded.graph.not_nil!
        loaded_graph.all_objects.to_h { |obj| {obj.id, obj.data} }.should eq(objects_before)
        loaded_graph.all_relations.to_h { |rel| {rel.id, rel.type} }.should eq(relations_before)

        # Stays appendable: new mints don't collide with archived ids.
        fresh = loaded_graph.add_object("task", %({"title":"c"}))
        fresh.id.should eq("task#3")
      ensure
        File.delete(db) if db && File.exists?(db)
      end
    end
  end
end
