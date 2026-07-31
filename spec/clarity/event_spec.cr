require "../spec_helper"

describe Clarity::Event do
  it "preserves replay-relevant metadata supplied by the platform edge" do
    event = Clarity::Event.new(
      schema_version: 1_u16,
      sequence: 42_u64,
      id: "evt_000042",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship deterministic routing"})
    )

    event.schema_version.should eq(1_u16)
    event.sequence.should eq(42_u64)
    event.id.should eq("evt_000042")
    event.type.should eq("goal.created")
    event.actor.should eq("user")
    event.caused_by.should be_nil
    event.timestamp.should eq(Time.utc(2026, 7, 24, 12, 0, 0))
    event.payload.should eq(%({"goal":"ship deterministic routing"}))
  end

  it "serializes its envelope with a stable field order" do
    event = Clarity::Event.new(
      schema_version: 1_u16,
      sequence: 42_u64,
      id: "evt_000042",
      type: "goal.created",
      actor: "user",
      caused_by: "evt_000041",
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship deterministic routing"})
    )

    event.canonical_json.should eq(
      %({"schema_version":1,"sequence":42,"id":"evt_000042","type":"goal.created","actor":"user","caused_by":"evt_000041","frame_id":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"ship deterministic routing"}})
    )
  end

  it "rejects a payload that cannot be embedded as JSON" do
    expect_raises(Clarity::InvalidEventError, "payload must be valid JSON") do
      Clarity::Event.new(
        schema_version: 1_u16,
        sequence: 42_u64,
        id: "evt_000042",
        type: "goal.created",
        actor: "user",
        caused_by: nil,
        timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
        payload: "not-json"
      )
    end
  end

  it "hashes its canonical envelope" do
    first = Clarity::Event.new(
      schema_version: 1_u16,
      sequence: 42_u64,
      id: "evt_000042",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship deterministic routing"})
    )
    second = Clarity::Event.new(
      schema_version: 1_u16,
      sequence: 43_u64,
      id: "evt_000043",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship deterministic routing"})
    )

    first.content_hash.should eq(first.content_hash)
    first.content_hash.size.should eq(64)
    first.content_hash.should_not eq(second.content_hash)
  end
end
