require "../spec_helper"

private def promote_event(
  type : String,
  id : String,
  actor : String = "runtime",
  caused_by : String? = nil,
  sequence : UInt64 = 1_u64,
) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: actor, caused_by: caused_by,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: %({}),
  )
end

describe Chronicle::RuntimeReason do
  it "promote_block? is true for the promote.applied marker" do
    marker = promote_event("promote.applied", "evt_marker")
    Chronicle::RuntimeReason.promote_block?(marker).should be_true
  end

  it "promote_block? is true for promote:-actor quiescent delta events" do
    delta = promote_event("object.created", "evt_delta", actor: "promote:parent", caused_by: "evt_marker")
    Chronicle::RuntimeReason.promote_block?(delta).should be_true
  end

  it "promote_block? is false for ordinary runtime events" do
    ordinary = promote_event("goal.created", "evt_goal")
    Chronicle::RuntimeReason.promote_block?(ordinary).should be_false
  end

  it "promote_block? is false for promote:-prefixed object types in payloads (not actors)" do
    # The predicate keys on the actor, not the payload — a normal event
    # whose payload merely mentions a promote: id is not a block event.
    evt = promote_event("object.created", "evt_plain")
    Chronicle::RuntimeReason.promote_block?(evt).should be_false
  end
end
