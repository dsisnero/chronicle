require "../spec_helper"

private def goal_event(id : String, goal : String, sequence : UInt64) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: "goal.created", actor: "user", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: JSON.build { |json| json.object { json.field "goal", goal } },
  )
end

private def plain_event(id : String, type : String, sequence : UInt64) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: "system", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: %({}),
  )
end

describe Chronicle::RuntimeReason do
  it "returns the first goal.created goal text" do
    events = [
      plain_event("evt_0", "object.created", 1_u64),
      goal_event("evt_1", "first goal", 2_u64),
      goal_event("evt_2", "second goal", 3_u64),
    ]
    Chronicle::RuntimeReason.first_goal(events).should eq("first goal")
  end

  it "returns nil when no goal.created event exists" do
    events = [plain_event("evt_0", "object.created", 1_u64)]
    Chronicle::RuntimeReason.first_goal(events).should be_nil
  end

  it "returns nil for an empty log" do
    Chronicle::RuntimeReason.first_goal([] of Chronicle::Event).should be_nil
  end
end
