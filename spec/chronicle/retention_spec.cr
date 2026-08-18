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
end
