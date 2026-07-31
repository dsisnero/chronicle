require "../spec_helper"

private def make_event(seq, id, type = "goal.created", caused_by = nil)
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: seq, id: id,
    type: type, actor: "test", caused_by: caused_by,
    timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
    payload: %({"seq":#{seq}}),
  )
end

describe Chronicle::MemoryEventStore do
  it "is initially empty" do
    store = Chronicle::MemoryEventStore.new
    store.count.should eq(0)
  end

  it "appends and retrieves events" do
    store = Chronicle::MemoryEventStore.new
    evt = make_event(1_u64, "evt_001")
    store.append(evt)

    store.count.should eq(1)
    retrieved = store.get_event("evt_001")
    retrieved.should_not be_nil
    retrieved.not_nil!.id.should eq("evt_001")
  end

  it "iterates events in sequence order" do
    store = Chronicle::MemoryEventStore.new
    store.append(make_event(1_u64, "evt_001"))
    store.append(make_event(2_u64, "evt_002"))
    store.append(make_event(3_u64, "evt_003"))

    events = store.iter_events
    events.size.should eq(3)
    events.map(&.id).should eq(["evt_001", "evt_002", "evt_003"])
  end

  it "iterates events after a given event ID" do
    store = Chronicle::MemoryEventStore.new
    store.append(make_event(1_u64, "evt_001"))
    store.append(make_event(2_u64, "evt_002"))
    store.append(make_event(3_u64, "evt_003"))

    events = store.iter_events(after: "evt_001")
    events.size.should eq(2)
    events.map(&.id).should eq(["evt_002", "evt_003"])
  end

  it "iterates events up to and including a given event ID" do
    store = Chronicle::MemoryEventStore.new
    store.append(make_event(1_u64, "evt_001"))
    store.append(make_event(2_u64, "evt_002"))
    store.append(make_event(3_u64, "evt_003"))
    store.append(make_event(4_u64, "evt_004"))

    events = store.iter_events(before: "evt_003")
    events.size.should eq(3)
    events.map(&.id).should eq(["evt_001", "evt_002", "evt_003"])
  end

  it "truncates events after a given event ID" do
    store = Chronicle::MemoryEventStore.new
    store.append(make_event(1_u64, "evt_001"))
    store.append(make_event(2_u64, "evt_002"))
    store.append(make_event(3_u64, "evt_003"))

    store.truncate_after("evt_001")
    store.count.should eq(1)
    store.get_event("evt_002").should be_nil
  end

  it "closes without error" do
    store = Chronicle::MemoryEventStore.new
    store.close
  end
end
