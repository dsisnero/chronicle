require "../spec_helper"

private def make_event(seq, id, type = "goal.created")
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: seq, id: id,
    type: type, actor: "test", caused_by: nil,
    timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
    payload: %({"seq":#{seq}}),
  )
end

describe Chronicle::SQLiteEventStore do
  it "is initially empty" do
    with_db do |path|
      store = Chronicle::SQLiteEventStore.new(path, "run_001")
      store.count.should eq(0)
      store.close
    end
  end

  it "appends and retrieves events" do
    with_db do |path|
      store = Chronicle::SQLiteEventStore.new(path, "run_001")
      store.append(make_event(1_u64, "evt_001"))

      store.count.should eq(1)
      retrieved = store.get_event("evt_001")
      retrieved.should_not be_nil
      retrieved.not_nil!.id.should eq("evt_001")
      store.close
    end
  end

  it "iterates events in sequence order" do
    with_db do |path|
      store = Chronicle::SQLiteEventStore.new(path, "run_001")
      store.append(make_event(1_u64, "evt_001"))
      store.append(make_event(2_u64, "evt_002"))
      store.append(make_event(3_u64, "evt_003"))

      events = store.iter_events
      events.size.should eq(3)
      events.map(&.id).should eq(["evt_001", "evt_002", "evt_003"])
      store.close
    end
  end

  it "persists to disk and reloads" do
    path = "/tmp/_clarity_sqlite_persist.db"
    File.delete(path) if File.exists?(path)

    store = Chronicle::SQLiteEventStore.new(path, "run_001")
    store.append(make_event(1_u64, "evt_001"))
    store.append(make_event(2_u64, "evt_002"))
    store.close

    store2 = Chronicle::SQLiteEventStore.new(path, "run_001")
    store2.count.should eq(2)
    events = store2.iter_events
    events.map(&.id).should eq(["evt_001", "evt_002"])
    store2.close

    File.delete(path)
  end

  it "truncates events after a given ID" do
    with_db do |path|
      store = Chronicle::SQLiteEventStore.new(path, "run_001")
      store.append(make_event(1_u64, "evt_001"))
      store.append(make_event(2_u64, "evt_002"))
      store.append(make_event(3_u64, "evt_003"))

      store.truncate_after("evt_001")
      store.count.should eq(1)
      store.get_event("evt_002").should be_nil
      store.close
    end
  end

  it "supports cursor-based iteration" do
    with_db do |path|
      store = Chronicle::SQLiteEventStore.new(path, "run_001")
      (1..5).each { |i| store.append(make_event(i.to_u64, "evt_00#{i}")) }

      after_evt2 = store.iter_events(after: "evt_002")
      after_evt2.size.should eq(3)

      before_evt4 = store.iter_events(before: "evt_004")
      before_evt4.size.should eq(4)

      store.close
    end
  end

  it "separates runs" do
    with_db do |path|
      store = Chronicle::SQLiteEventStore.new(path, "run_a")
      store.append(make_event(1_u64, "evt_001"))
      store.close

      store_b = Chronicle::SQLiteEventStore.new(path, "run_b")
      store_b.count.should eq(0)
      store_b.close
    end
  end
end

private def with_db(&)
  path = "/tmp/_clarity_sqlite_#{Process.pid}_#{rand(10000)}.db"
  File.delete(path) if File.exists?(path)
  yield path
  File.delete(path) if File.exists?(path)
end
