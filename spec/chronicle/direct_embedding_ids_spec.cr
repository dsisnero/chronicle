require "../spec_helper"

private def embedding_event(id : String, type : String, caused_by : String?, sequence : UInt64) : Chronicle::Event
  payload = type == "embedding.requested" ? %({"inputs_hash":"abc123"}) : %({"vectors":[[1.0]]})
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: "provider", caused_by: caused_by,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

describe Chronicle::RuntimeReason do
  it "collects operator-invoked embedding request/response ids (upstream _direct_embedding_event_ids)" do
    events = [
      embedding_event("evt_request_1", "embedding.requested", nil, 1_u64),
      embedding_event("evt_responded_1", "embedding.responded", "evt_request_1", 2_u64),
      embedding_event("evt_request_2", "embedding.requested", "evt_goal", 3_u64),
      embedding_event("evt_responded_2", "embedding.responded", "evt_request_2", 4_u64),
    ]
    ids = Chronicle::RuntimeReason.direct_embedding_event_ids(events)
    ids.should eq(Set{"evt_request_1", "evt_responded_1"})
  end

  it "excludes behavior-derived embedding calls (caused_by present on the request)" do
    events = [
      embedding_event("evt_goal", "goal.created", nil, 1_u64),
      embedding_event("evt_request", "embedding.requested", "evt_goal", 2_u64),
      embedding_event("evt_responded", "embedding.responded", "evt_request", 3_u64),
    ]
    Chronicle::RuntimeReason.direct_embedding_event_ids(events).should be_empty
  end

  it "collects a direct request with no response" do
    events = [
      embedding_event("evt_request", "embedding.requested", nil, 1_u64),
    ]
    ids = Chronicle::RuntimeReason.direct_embedding_event_ids(events)
    ids.should eq(Set{"evt_request"})
  end

  it "excludes a response whose request was not operator-invoked" do
    events = [
      embedding_event("evt_goal", "goal.created", nil, 1_u64),
      embedding_event("evt_request", "embedding.requested", "evt_goal", 2_u64),
      embedding_event("evt_responded", "embedding.responded", "evt_request", 3_u64),
      embedding_event("evt_direct_request", "embedding.requested", nil, 4_u64),
      embedding_event("evt_direct_responded", "embedding.responded", "evt_direct_request", 5_u64),
    ]
    ids = Chronicle::RuntimeReason.direct_embedding_event_ids(events)
    ids.should eq(Set{"evt_direct_request", "evt_direct_responded"})
  end

  it "is empty for a log with no embedding events" do
    events = [
      embedding_event("evt_goal", "goal.created", nil, 1_u64),
    ]
    Chronicle::RuntimeReason.direct_embedding_event_ids(events).should be_empty
  end
end
