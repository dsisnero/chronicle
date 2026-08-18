require "json"
require "set"

module Chronicle
  # Compaction and retention: snapshot + archive tier, never deletion
  # (CONTRACT v1.5 #2, phase 1 of the compaction design). Ported from
  # activegraph store/retention.py.
  #
  # This module owns the pure / read-only surfaces: the pin set (`pins`), the
  # snapshot blob helpers, and the structured errors. The SQLite archive/
  # snapshot mutations (`compact` / `retire` / `verify_snapshot`) extend
  # SQLiteEventStore and are layered on top.
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
  end
end
