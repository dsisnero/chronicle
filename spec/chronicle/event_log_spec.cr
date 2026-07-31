require "../spec_helper"

module EventLogSpecHelper
  extend self

  def event(sequence : UInt64, id : String, caused_by : String? = nil) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: sequence,
      id: id,
      type: "goal.created",
      actor: "user",
      caused_by: caused_by,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship deterministic routing"})
    )
  end
end

describe Chronicle::EventLog do
  it "appends events in strictly increasing sequence order" do
    log = Chronicle::EventLog.new
    first = EventLogSpecHelper.event(sequence: 1_u64, id: "evt_000001")
    second = EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002", caused_by: first.id)

    log.append(first)
    log.append(second)

    log.events.should eq([first, second])
  end

  it "rejects a sequence that does not advance the log" do
    log = Chronicle::EventLog.new
    log.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002"))

    expect_raises(Chronicle::EventSequenceError, "event sequence must increase") do
      log.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002b"))
    end
  end

  it "rejects an event ID that is already present" do
    log = Chronicle::EventLog.new
    log.append(EventLogSpecHelper.event(sequence: 1_u64, id: "evt_000001"))

    expect_raises(Chronicle::DuplicateEventError, "event id must be unique") do
      log.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000001"))
    end
  end

  it "rejects an event whose causal parent is absent" do
    log = Chronicle::EventLog.new

    expect_raises(Chronicle::CausalParentError, "caused_by event must exist") do
      log.append(
        EventLogSpecHelper.event(
          sequence: 1_u64,
          id: "evt_000001",
          caused_by: "evt_000000"
        )
      )
    end
  end

  it "forks an independent suffix from a shared event prefix" do
    log = Chronicle::EventLog.new
    first = EventLogSpecHelper.event(sequence: 1_u64, id: "evt_000001")
    second = EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002", caused_by: first.id)
    log.append(first)
    log.append(second)

    fork = log.fork_at(1_u64)
    fork.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_fork_000002", caused_by: first.id))

    log.events.map(&.id).should eq(["evt_000001", "evt_000002"])
    fork.events.map(&.id).should eq(["evt_000001", "evt_fork_000002"])
  end
end

describe Chronicle::EventLogCodec do
  it "encodes and decodes a versioned log without changing canonical events" do
    first = EventLogSpecHelper.event(sequence: 1_u64, id: "evt_000001")
    second = EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002", caused_by: first.id)
    log = Chronicle::EventLog.from_events([first, second])

    encoded = Chronicle::EventLogCodec.encode(log)
    decoded = Chronicle::EventLogCodec.decode(encoded)

    encoded.should eq(
      %({"format":"chronicle.event-log","version":1}\n#{first.canonical_json}\n#{second.canonical_json}\n)
    )
    decoded.events.map(&.canonical_json).should eq(log.events.map(&.canonical_json))
    Chronicle::EventLogCodec.encode(decoded).should eq(encoded)
  end

  it "rejects an unsupported log format version" do
    encoded = %({"format":"chronicle.event-log","version":2}\n)

    expect_raises(Chronicle::InvalidLogEncodingError, /unsupported event log format version/) do
      Chronicle::EventLogCodec.decode(encoded)
    end
  end

  it "rejects a malformed event record" do
    encoded = %({"format":"chronicle.event-log","version":1}\n{"sequence":1}\n)

    expect_raises(Chronicle::InvalidLogEncodingError, /invalid event record/) do
      Chronicle::EventLogCodec.decode(encoded)
    end
  end
end
