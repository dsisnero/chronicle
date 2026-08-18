require "../spec_helper"

# Cross-store migration (upstream observability/migration.py, CONTRACT v0.8
# #5): copy every run (lineage + events) from a source store into a
# destination store, transaction-per-run with idempotent INSERT OR IGNORE.
# A structured per-run report is returned; a bad run does not block the
# others. The SQLite -> SQLite path is ported; Postgres stays deferred.

require "file"
require "file_utils"

private def migration_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_migration_#{tag}_#{Random::Secure.hex(4)}.db")
end

private def migration_event(id : String, type : String, payload : String = %({})) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: id,
    type: type, actor: "test", caused_by: nil,
    timestamp: Time.utc, payload: payload,
  )
end

private def migration_source(tag : String)
  db = migration_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
  store.append(migration_event("goal", "goal.created", %({"goal":"first"})))
  store.append(migration_event("obj", "object.created", %({"id":"task#1","type":"task","data":{"title":"a"},"version":1,"provenance":{}})))
  db
end

describe Chronicle::Migration do
  describe "MigrationReport" do
    it "is ok when nothing failed and exposes failures" do
      run = Chronicle::Migration::RunReport.new(run_id: "r", status: "ok", events_migrated: 2)
      report = Chronicle::Migration::Report.new(source_url: "sqlite:///a", dest_url: "sqlite:///b", runs: [run])
      report.ok?.should be_true
      report.failures.should be_empty
    end

    it "is not ok and lists failures when a run failed" do
      run = Chronicle::Migration::RunReport.new(run_id: "r", status: "failed", events_migrated: 0, error: "write failure: boom")
      report = Chronicle::Migration::Report.new(source_url: "sqlite:///a", dest_url: "sqlite:///b", runs: [run])
      report.ok?.should be_false
      report.failures.size.should eq(1)
      report.failures[0].error.should eq("write failure: boom")
    end
  end

  describe ".migrate" do
    it "copies every run's events to the destination and reports ok" do
      src = migration_source("copy")
      dst = migration_db_path("copy_dst")

      report = Chronicle::Migration.migrate("sqlite:///#{src}", "sqlite:///#{dst}")
      report.ok?.should be_true
      report.runs.size.should eq(1)
      report.runs[0].run_id.should eq("parent")
      report.runs[0].status.should eq("ok")
      report.runs[0].events_migrated.should eq(2)

      dest_store = Chronicle::SQLiteEventStore.new(dst, run_id: "parent")
      dest_store.iter_events.map(&.id).should eq(["goal", "obj"])
      dest_store.count.should eq(2)
    end

    it "is idempotent: a re-migrate writes no new rows" do
      src = migration_source("idem")
      dst = migration_db_path("idem_dst")
      Chronicle::Migration.migrate("sqlite:///#{src}", "sqlite:///#{dst}")

      report = Chronicle::Migration.migrate("sqlite:///#{src}", "sqlite:///#{dst}")
      report.runs[0].events_migrated.should eq(0)
    end

    it "honors only_run_ids" do
      src = migration_source("subset")
      dst = migration_db_path("subset_dst")

      report = Chronicle::Migration.migrate("sqlite:///#{src}", "sqlite:///#{dst}", only_run_ids: ["nope"])
      report.runs.size.should eq(0)

      report2 = Chronicle::Migration.migrate("sqlite:///#{src}", "sqlite:///#{dst}", only_run_ids: ["parent"])
      report2.runs.size.should eq(1)
    end

    it "reports an empty source as ok with no runs" do
      src = migration_db_path("empty_src")
      dst = migration_db_path("empty_dst")
      store = Chronicle::SQLiteEventStore.new(src, run_id: "parent")
      conn = DB.open("sqlite3://#{src}")
      conn.exec("DELETE FROM runs")
      conn.close

      report = Chronicle::Migration.migrate("sqlite:///#{src}", "sqlite:///#{dst}")
      report.ok?.should be_true
      report.runs.should be_empty
    end
  end
end
