require "json"

module Chronicle
  # Cross-store migration (upstream observability/migration.py, CONTRACT v0.8
  # #5): copy every run (lineage + events) from a source store into a
  # destination store. Each run migrates in a single transaction against the
  # destination; writes use idempotent INSERT OR IGNORE against
  # `UNIQUE(id, run_id)` so re-running after a failure is idempotent. Runs
  # migrate independently — a bad run does not block the others. A structured
  # per-run report is returned. Migration is one-directional and explicit.
  #
  # The SQLite -> SQLite path is ported; Postgres (and `skip_corrupted`) stay
  # deferred.
  module Migration
    extend self

    # Outcome of migrating one run between stores. `status` is "ok" (copied),
    # "skipped" (already present at the destination), or "failed" (with
    # `error` set); `events_migrated` counts rows written this invocation.
    record RunReport,
      run_id : String,
      status : String,
      events_migrated : Int32,
      error : String? = nil,
      skipped_events : Array(String) = [] of String

    # Aggregate result of a store-to-store migration: one RunReport per run
    # found at the source; `ok?` is true when nothing failed (skips are fine);
    # `failures` filters the runs that need attention.
    record Report, source_url : String, dest_url : String, runs : Array(RunReport) do
      # True when every run's status is "ok" or "skipped" (nothing failed).
      def ok? : Bool
        runs.all? { |run| run.status != "failed" }
      end

      # The runs that failed and need attention.
      def failures : Array(RunReport)
        runs.select { |run| run.status == "failed" }
      end
    end

    # Copy every run (or a subset) from `source_url` into `dest_url`.
    # `on_progress` is called after each run finishes (success or failure)
    # with that run's report. Returns a `Report`; the operation is considered
    # successful iff every run's status is "ok" or "skipped".
    def migrate(
      source_url : String,
      dest_url : String,
      *,
      only_run_ids : Array(String)? = nil,
      on_progress : Proc(RunReport, Nil)? = nil,
      skip_corrupted : Bool = false,
    ) : Report
      raise IncompatibleRuntimeState.new("migration skip_corrupted is not yet ported") if skip_corrupted

      src = resolve_path(source_url, "source")
      dst = resolve_path(dest_url, "destination")

      records = SQLiteEventStore.list_runs(src)
      records = records.select { |rec| only_run_ids.includes?(rec.run_id) } if only_run_ids

      reports = records.map do |rec|
        report = migrate_one_run(src, dst, rec)
        on_progress.try(&.call(report))
        report
      end
      Report.new(source_url: source_url, dest_url: dest_url, runs: reports)
    end

    private def resolve_path(url : String, role : String) : String
      parsed = Chronicle.parse_store_url(url)
      if parsed.scheme != "sqlite"
        raise IncompatibleRuntimeState.new(
          "#{role} store URL #{url.inspect} uses scheme #{parsed.scheme.inspect}; migration currently supports sqlite only"
        )
      end
      parsed.sqlite_path || raise IncompatibleRuntimeState.new("#{role} store URL #{url.inspect} has no resolvable path")
    end

    private def migrate_one_run(src : String, dst : String, rec : SQLiteEventStore::RunRecord) : RunReport
      src_store = SQLiteEventStore.new(src, run_id: rec.run_id)
      begin
        events = src_store.iter_events
      rescue ex : Exception
        return RunReport.new(run_id: rec.run_id, status: "failed", events_migrated: 0, error: "read failure: #{ex.message}")
      ensure
        src_store.close
      end

      begin
        n = SQLiteEventStore.migrate_run(dst, rec, events)
      rescue ex : Exception
        return RunReport.new(run_id: rec.run_id, status: "failed", events_migrated: 0, error: "write failure: #{ex.message}")
      end
      RunReport.new(run_id: rec.run_id, status: "ok", events_migrated: n)
    end
  end
end
