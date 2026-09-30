require "../spec_helper"

# The event store is the sequencing authority (upstream: `Event` has no
# `sequence`; SQLite/Postgres assign `seq` AUTOINCREMENT/BIGSERIAL on append).
# A store must therefore produce a strictly-increasing log regardless of the
# provisional sequence an emitter stamped on the event — otherwise a
# memory-backed run's log is not directly codec-encodable.

private def sequencing_event(id : String, sequence : UInt64, payload : String = %({"k":"v"})) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: "object.created", actor: "test", caused_by: nil,
    timestamp: Time.utc(2026, 1, 1, 0, 0, 0), payload: payload,
  )
end

describe Chronicle::MemoryEventStore do
  it "assigns the append position as the sequence, ignoring the emitter's value" do
    store = Chronicle::MemoryEventStore.new
    # Non-monotonic/duplicate provisional sequences: 5, 5, 1, 0.
    store.append(sequencing_event("evt_a", 5_u64))
    store.append(sequencing_event("evt_b", 5_u64))
    store.append(sequencing_event("evt_c", 1_u64))
    store.append(sequencing_event("evt_d", 0_u64))

    store.iter_events.map(&.sequence).should eq([1_u64, 2_u64, 3_u64, 4_u64])
    store.get_event("evt_c").not_nil!.sequence.should eq(3_u64)
  end

  it "keeps the log directly EventLogCodec-encodable" do
    store = Chronicle::MemoryEventStore.new
    store.append(sequencing_event("evt_a", 9_u64))
    store.append(sequencing_event("evt_b", 2_u64))
    store.append(sequencing_event("evt_c", 7_u64))

    log = Chronicle::EventLog.from_events(store.iter_events)
    decoded = Chronicle::EventLogCodec.decode(Chronicle::EventLogCodec.encode(log))
    decoded.events.map(&.id).should eq(["evt_a", "evt_b", "evt_c"])
    decoded.events.map(&.sequence).should eq([1_u64, 2_u64, 3_u64])
  end
end
