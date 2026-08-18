require "json"
require "set"

module Chronicle
  # Compaction and retention: snapshot + archive tier, never deletion
  # (CONTRACT v1.5 #2, phase 1 of the compaction design). Ported from
  # activegraph store/retention.py.
  #
  # The pin set (`pins`) dominates retention policy unconditionally;
  # `retire` archives a whole closed unpinned run. The SQLite
  # snapshot/archive mutations live on SQLiteEventStore; the snapshot
  # reconstruction on load is layered on top.
  module Retention
    extend self

    # A compact/retire was refused because the run is pinned. `reasons`
    # carries every pin (the same list `pins` returns), so one look answers
    # "why can't I retire this run?".
    class RetentionPinnedError < StorageError
      DOC_SLUG = "retention-pinned-error"

      getter run_id : String
      getter operation : String
      getter reasons : Array(String)

      def initialize(@run_id : String, @operation : String, @reasons : Array(String))
        listing = @reasons.map { |reason| "    - #{reason}" }.join("\n")
        super(
          "#{@operation} refused: run #{@run_id.inspect} is pinned",
          what_failed: (
            "#{@operation}(#{@run_id.inspect}) was refused because the run " \
            "is pinned:\n#{listing}"
          ),
          why: (
            "The pin set dominates retention policy unconditionally " \
            "(CONTRACT v1.5 #2). Promoted-from fork logs are provenance for " \
            "adopted state; runs with live children anchor their descendants' " \
            "lineage; unresolved machinery (approvals, proposed patches) is " \
            "recorded state a summary cannot carry. Archiving any of these " \
            "would break audit walks that are contractual."
          ),
          how_to_fix: (
            "Resolve each pin first: retire abandoned descendant runs before " \
            "their parent, resolve pending approvals and proposed patches, and " \
            "accept that promoted-from forks stay — they are not garbage, " \
            "they are provenance."
          ),
          context: {
            "run_id"    => JSON::Any.new(run_id),
            "operation" => JSON::Any.new(operation),
            "reasons"   => JSON::Any.new(reasons.map { |reason| JSON::Any.new(reason) }),
          },
        )
      end

      def self.doc_slug : String
        DOC_SLUG
      end
    end

    # `"sha256:" + hex` over the canonical snapshot blob bytes (upstream
    # `state_hash_of`). The state hash recorded in the runtime.snapshot event
    # keeps the sidecar blob honest.
    def state_hash_of(blob : String) : String
      "sha256:" + ContentHash.digest(blob)
    end

    # Every reason `run_id` cannot be compacted or retired (upstream `pins`).
    # Empty list = unpinned. The pin set dominates retention policy
    # unconditionally: promoted-from fork logs, live children, unresolved
    # approvals / proposed patches all pin. Read-only.
    def pins(path : String, run_id : String) : Array(String)
      records = SQLiteEventStore.list_runs(path)
      promoted_from_pins(path, records, run_id) +
        live_lineage_pins(path, records, run_id) +
        pending_machinery_pins(path, run_id)
    end

    # Pin 1 (the normative retention pin): promoted-from. Scan every OTHER
    # run's hot events for promote.applied markers naming us.
    private def promoted_from_pins(path : String, records : Array(SQLiteEventStore::RunRecord), run_id : String) : Array(String)
      reasons = [] of String
      records.each do |record|
        next if record.run_id == run_id

        other = SQLiteEventStore.new(path, run_id: record.run_id)
        begin
          other.iter_events.each do |event|
            next unless event.type == "promote.applied"

            payload = JSON.parse(event.payload).as_h?
            if payload.try(&.["from_run"]?.try(&.as_s)) == run_id
              reasons << (
                "promoted-from: run #{record.run_id.inspect} adopted this " \
                "run's state at marker #{event.id.inspect}; the whole fork " \
                "log is provenance for that promote"
              )
              break
            end
          rescue JSON::ParseException
            next
          end
        ensure
          other.close
        end
      end
      reasons
    end

    # Pin 2: live lineage — children whose hot log still exists.
    private def live_lineage_pins(path : String, records : Array(SQLiteEventStore::RunRecord), run_id : String) : Array(String)
      reasons = [] of String
      records.each do |record|
        next unless record.parent_run_id == run_id

        child = SQLiteEventStore.new(path, run_id: record.run_id)
        begin
          next if child.iter_events.empty?

          reasons << (
            "live-lineage: run #{record.run_id.inspect} forked from this run " \
            "at #{record.forked_at_event_id.inspect} and is not retired"
          )
        ensure
          child.close
        end
      end
      reasons
    end

    # Pin 4: pending machinery — unresolved approvals, proposed patches.
    private def pending_machinery_pins(path : String, run_id : String) : Array(String)
      reasons = [] of String
      pending_approvals, proposed_patches = scan_pending_machinery(path, run_id)
      unless pending_approvals.empty?
        reasons << "pending-approvals: #{pending_approvals.join(", ")} are unresolved"
      end
      unless proposed_patches.empty?
        reasons << (
          "proposed-patches: #{proposed_patches.join(", ")} are " \
          "neither applied nor rejected"
        )
      end
      reasons
    end

    # Scan a run's hot log for unresolved approvals (proposed minus granted)
    # and proposed-but-unresolved patches. Both sort deterministically.
    private def scan_pending_machinery(path : String, run_id : String) : {Array(String), Array(String)}
      proposed_approvals = Set(String).new
      granted = Set(String).new
      proposed_patches = {} of String => String
      store = SQLiteEventStore.new(path, run_id: run_id)
      begin
        store.iter_events.each do |event|
          payload = JSON.parse(event.payload).as_h?
          case event.type
          when "approval.proposed"
            proposed_approvals << (payload.try(&.["approval_id"]?.try(&.as_s)) || "")
          when "approval.granted"
            granted << (payload.try(&.["approval_id"]?.try(&.as_s)) || "")
          when "patch.proposed"
            patch = payload.try(&.["patch"]?.try(&.as_h?))
            proposed_patches[patch.try(&.["id"]?.try(&.as_s)) || ""] = "proposed"
          when "patch.applied"
            patch = payload.try(&.["patch"]?.try(&.as_h?))
            proposed_patches.delete(patch.try(&.["id"]?.try(&.as_s)) || "")
          when "patch.rejected"
            proposed_patches.delete(payload.try(&.["patch_id"]?.try(&.as_s)) || "")
          end
        rescue JSON::ParseException
          next
        end
      ensure
        store.close
      end
      {(proposed_approvals - granted).to_a.sort, proposed_patches.keys.sort!}
    end

    # Archive an entire closed, unpinned run (upstream `retire`). Returns rows
    # moved. The typical subject is a rejected fork trial that was never
    # promoted; pinned runs refuse with the full reason list. Offline
    # operation, per-run: no live runtime may be attached to `run_id` itself.
    def retire(path : String, run_id : String) : Int32
      reasons = pins(path, run_id)
      unless reasons.empty?
        raise RetentionPinnedError.new(run_id: run_id, operation: "retire", reasons: reasons)
      end

      store = SQLiteEventStore.new(path, run_id: run_id)
      begin
        store.archive_run(archived_at: RuntimeReason.now_iso)
      ensure
        store.close
      end
    end

    # The snapshot blob: full projected state, canonical JSON (upstream
    # `_canonical_state_blob`). Provenance is INCLUDED — the snapshot must
    # reconstruct state faithfully. Determinism comes from sorted ids and
    # sorted keys; the state hash is computed over exactly these bytes.
    def canonical_state_blob(graph : GraphProjection) : String
      objects = graph.all_objects
        .map { |obj| JSON.parse(obj.to_json) }
        .sort_by!(&.["id"].as_s)
      relations = graph.all_relations
        .map { |relation| JSON.parse(relation.to_json) }
        .sort_by!(&.["id"].as_s)
      state = {
        "objects"   => JSON::Any.new(objects),
        "relations" => JSON::Any.new(relations),
      }
      Prompt.canonical_json(JSON::Any.new(state))
    end

    # Snapshot `run_id` and archive its pre-snapshot prefix (upstream
    # `compact`). Refuses pinned runs and emits the snapshot event, stores the
    # blob, then moves the prefix to the archive (crash-safe order, idempotent).
    # Returns the snapshot event id. Offline operation, per-run.
    def compact(path : String, run_id : String) : String
      reasons = pins(path, run_id)
      unless reasons.empty?
        raise RetentionPinnedError.new(run_id: run_id, operation: "compact", reasons: reasons)
      end

      store = SQLiteEventStore.new(path, run_id: run_id)
      begin
        events = store.iter_events
        graph = GraphProjection.replay(events)
        blob = canonical_state_blob(graph)
        digest = state_hash_of(blob)
        covered = events.size
        last_id = events.last?.try(&.id)

        seq = store.count + 1
        snapshot_event = Event.new(
          schema_version: 1_u16,
          sequence: seq.to_u64,
          id: "runtime_snapshot_#{seq}",
          type: "runtime.snapshot",
          actor: "runtime",
          caused_by: nil,
          timestamp: Time.utc,
          payload: JSON.build do |json|
            json.object do
              json.field "state_hash", digest
              json.field "covers_through", last_id
              json.field "events_covered", covered
              json.field "id_counters", graph.ids.snapshot_counters
            end
          end,
        )
        store.append(snapshot_event)
        store.put_snapshot(digest, blob, created_at: RuntimeReason.now_iso)
        store.archive_prefix(store.seq_of(snapshot_event.id), archived_at: RuntimeReason.now_iso)
        snapshot_event.id
      ensure
        store.close
      end
    end

    # Replay the archived prefix and prove it reproduces the snapshot
    # (upstream `verify_snapshot`). Returns True on match; raises
    # SnapshotIntegrityError on mismatch; raises LookupError when the run has
    # no snapshot.
    def verify_snapshot(path : String, run_id : String) : Bool
      store = SQLiteEventStore.new(path, run_id: run_id)
      begin
        snapshot_event = store.iter_events.find { |event| event.type == "runtime.snapshot" }
        if snapshot_event.nil?
          raise KeyError.new("run #{run_id.inspect} has no runtime.snapshot event")
        end
        expected = JSON.parse(snapshot_event.payload).as_h["state_hash"]?.try(&.as_s) || ""

        scratch = GraphProjection.replay(store.iter_archived)
        actual = state_hash_of(canonical_state_blob(scratch))
        if actual != expected
          raise SnapshotIntegrityError.new(
            run_id: run_id, expected: expected,
            detail: "archived prefix replays to #{actual}, event pins #{expected}.",
          )
        end
        true
      ensure
        store.close
      end
    end

    # A snapshot blob does not hash-match its runtime.snapshot event —
    # corruption, refused loudly at load (CONTRACT v1.5 #2).
    class SnapshotIntegrityError < StorageError
      DOC_SLUG = "snapshot-integrity-error"

      getter run_id : String
      getter expected : String

      def initialize(@run_id : String, @expected : String, detail : String)
        super(
          "snapshot integrity failure in run #{@run_id.inspect}",
          what_failed: (
            "Loading run #{@run_id.inspect}: the snapshot referenced by its " \
            "runtime.snapshot event failed verification. #{detail}"
          ),
          why: (
            "A compacted run's projected state is reconstructed from the " \
            "snapshot blob; the state hash recorded in the event is what " \
            "keeps the blob honest. A mismatch means the sidecar was " \
            "corrupted or tampered with, and replaying from it would " \
            "silently produce wrong state."
          ),
          how_to_fix: (
            "Verify the archived prefix is intact and rebuild the snapshot " \
            "from it. If the archive replays clean, re-compact; if not, " \
            "restore the store file from backup."
          ),
          context: {"run_id" => JSON::Any.new(run_id), "expected_hash" => JSON::Any.new(expected)},
        )
      end

      def self.doc_slug : String
        DOC_SLUG
      end
    end
  end
end
