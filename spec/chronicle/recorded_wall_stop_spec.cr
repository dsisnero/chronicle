require "../spec_helper"

private def wall_stop_event(
  id : String,
  exhausted_by : String?,
  accepted_sequence : Int32?,
  max_seconds : Float64?,
  sequence : UInt64,
) : Chronicle::Event
  payload = JSON.build do |json|
    json.object do
      json.field "exhausted_by", exhausted_by
      json.field "stop_position" do
        json.object do
          json.field "accepted_sequence", accepted_sequence
        end
      end
      json.field "snapshot" do
        json.object do
          json.field "limits" do
            json.object do
              json.field "max_seconds", max_seconds
            end
          end
        end
      end
    end
  end
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: "runtime.budget_exhausted", actor: "runtime", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

private def plain_event(id : String, type : String, sequence : UInt64) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: "runtime", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: %({}),
  )
end

describe Chronicle::RuntimeReason do
  it "returns the recorded wall-stop boundary (sequence, max_seconds limit)" do
    events = [
      wall_stop_event("evt_1", exhausted_by: "max_seconds", accepted_sequence: 42, max_seconds: 0.25, sequence: 1_u64),
    ]
    result = Chronicle::RuntimeReason.recorded_wall_stop(events)
    result.should eq({42_i64, 0.25})
  end

  it "returns nil when the stop was not a max_seconds exhaustion" do
    events = [
      wall_stop_event("evt_1", exhausted_by: "max_events", accepted_sequence: 42, max_seconds: nil, sequence: 1_u64),
    ]
    Chronicle::RuntimeReason.recorded_wall_stop(events).should be_nil
  end

  it "returns nil when no budget-exhausted event exists" do
    events = [plain_event("evt_1", "runtime.idle", 1_u64)]
    Chronicle::RuntimeReason.recorded_wall_stop(events).should be_nil
  end

  it "returns a nil max_seconds limit when the snapshot lacks it" do
    events = [
      wall_stop_event("evt_1", exhausted_by: "max_seconds", accepted_sequence: 7, max_seconds: nil, sequence: 1_u64),
    ]
    Chronicle::RuntimeReason.recorded_wall_stop(events).should eq({7_i64, nil})
  end
end
