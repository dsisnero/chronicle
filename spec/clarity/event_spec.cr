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
end
