require "../spec_helper"

private def llm_event(id : String, type : String, caused_by : String?, sequence : UInt64) : Chronicle::Event
  payload = type == "llm.failed" ? %({"error_class":"Timeout"}) : %({"text":"ok"})
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: "provider", caused_by: caused_by,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

describe Chronicle::RuntimeReason do
  it "collects failed-attempt request and response ids (upstream _non_replayable_llm_attempt_event_ids)" do
    events = [
      llm_event("evt_request_1", "llm.requested", nil, 1_u64),
      llm_event("evt_failed_1", "llm.failed", "evt_request_1", 2_u64),
      llm_event("evt_request_2", "llm.requested", nil, 3_u64),
      llm_event("evt_responded_2", "llm.responded", "evt_request_2", 4_u64),
    ]
    ids = Chronicle::RuntimeReason.non_replayable_llm_attempt_event_ids(events)
    ids.should eq(Set{"evt_failed_1", "evt_request_1"})
  end

  it "skips successful attempts entirely" do
    events = [
      llm_event("evt_request", "llm.requested", nil, 1_u64),
      llm_event("evt_responded", "llm.responded", "evt_request", 2_u64),
    ]
    Chronicle::RuntimeReason.non_replayable_llm_attempt_event_ids(events).should be_empty
  end

  it "handles a failed attempt with no caused_by request" do
    events = [
      llm_event("evt_failed", "llm.failed", nil, 1_u64),
    ]
    ids = Chronicle::RuntimeReason.non_replayable_llm_attempt_event_ids(events)
    ids.should eq(Set{"evt_failed"})
  end
end
