require "../spec_helper"

describe Chronicle::RuntimeReason do
  it "returns the most recent run id from a SQLite store" do
    dir = pack_spec_dir("most_recent_run_id")
    path = File.join(dir, "run.db")
    store = Chronicle::SQLiteEventStore.new(path, run_id: "run_first")
    store.upsert_run(created_at: Time.utc(2026, 7, 24, 10, 0, 0).to_rfc3339)
    store.close

    store2 = Chronicle::SQLiteEventStore.new(path, run_id: "run_second")
    store2.upsert_run(created_at: Time.utc(2026, 7, 24, 11, 0, 0).to_rfc3339)
    store2.close

    Chronicle::RuntimeReason.most_recent_run_id(path).should eq("run_second")
  end

  it "returns nil for a fresh/empty store" do
    dir = pack_spec_dir("most_recent_run_id_empty")
    path = File.join(dir, "empty.db")
    # A store with no runs yet.
    store = Chronicle::SQLiteEventStore.new(path, run_id: "run_solo")
    store.close
    # Fresh path never opened: list_runs returns [].
    Chronicle::RuntimeReason.most_recent_run_id(File.join(dir, "never.db")).should be_nil
  end
end
