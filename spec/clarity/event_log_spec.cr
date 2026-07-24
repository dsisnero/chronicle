require "../spec_helper"

module EventLogSpecHelper
  extend self

  def event(sequence : UInt64, id : String, caused_by : String? = nil) : Clarity::Event
    Clarity::Event.new(
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

describe Clarity::EventLog do
  it "appends events in strictly increasing sequence order" do
    log = Clarity::EventLog.new
    first = EventLogSpecHelper.event(sequence: 1_u64, id: "evt_000001")
    second = EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002", caused_by: first.id)

    log.append(first)
    log.append(second)

    log.events.should eq([first, second])
  end

  it "rejects a sequence that does not advance the log" do
    log = Clarity::EventLog.new
    log.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002"))

    expect_raises(Clarity::EventSequenceError, "event sequence must increase") do
      log.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000002b"))
    end
  end

  it "rejects an event ID that is already present" do
    log = Clarity::EventLog.new
    log.append(EventLogSpecHelper.event(sequence: 1_u64, id: "evt_000001"))

    expect_raises(Clarity::DuplicateEventError, "event id must be unique") do
      log.append(EventLogSpecHelper.event(sequence: 2_u64, id: "evt_000001"))
    end
  end

  it "rejects an event whose causal parent is absent" do
    log = Clarity::EventLog.new

    expect_raises(Clarity::CausalParentError, "caused_by event must exist") do
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
    log = Clarity::EventLog.new
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
