require "../spec_helper"

describe Chronicle::RuntimeReason do
  it "opens a SQLite store from a bare path with the given run_id" do
    dir = pack_spec_dir("open_sqlite_store_path")
    path = File.join(dir, "run.db")
    store = Chronicle::RuntimeReason.open_sqlite_store(path, run_id: "run_one")
    store.should be_a(Chronicle::SQLiteEventStore)
    store.as(Chronicle::SQLiteEventStore).run_id.should eq("run_one")
    store.as(Chronicle::SQLiteEventStore).db_path.should eq(path)
    store.close
  end

  it "opens a SQLite store from a relative sqlite:/// URL at its resolved path" do
    dir = pack_spec_dir("open_sqlite_store_relative_url")
    path = File.join(dir, "run.db")
    store = Chronicle::RuntimeReason.open_sqlite_store("sqlite:///#{path}", run_id: "run_url")
    store.should be_a(Chronicle::SQLiteEventStore)
    store.as(Chronicle::SQLiteEventStore).run_id.should eq("run_url")
    store.as(Chronicle::SQLiteEventStore).db_path.should eq(path)
    store.close
  end

  it "opens a SQLite store from an absolute sqlite://// URL at its resolved path" do
    dir = pack_spec_dir("open_sqlite_store_absolute_url")
    path = File.expand_path(File.join(dir, "run.db"))
    store = Chronicle::RuntimeReason.open_sqlite_store("sqlite:////#{path.lstrip('/')}", run_id: "run_abs")
    store.should be_a(Chronicle::SQLiteEventStore)
    store.as(Chronicle::SQLiteEventStore).run_id.should eq("run_abs")
    store.as(Chronicle::SQLiteEventStore).db_path.should eq(path)
    store.close
  end

  if postgres_url = ENV["CHRONICLE_POSTGRES_URL"]?
    it "dispatches a postgres URL through the common store factory" do
      store = Chronicle::RuntimeReason.open_sqlite_store(postgres_url, run_id: "run_pg")
      store.should be_a(Chronicle::PostgresEventStore)
      store.close
    end
  end
end
