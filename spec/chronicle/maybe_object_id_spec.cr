require "../spec_helper"

private def id_event(type : String, payload : String, id : String = "evt_1") : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: id,
    type: type, actor: "system", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

describe Chronicle::RuntimeReason do
  it "extracts the object id from an object.created payload" do
    event = id_event("object.created", %({"id":"doc#1","type":"doc","data":{}}))
    Chronicle::RuntimeReason.maybe_object_id(event).should eq("doc#1")
  end

  it "extracts the object id from a relation.created payload" do
    event = id_event("relation.created", %({"id":"rel_1","type":"links","from_id":"doc#1","to_id":"doc#2"}))
    Chronicle::RuntimeReason.maybe_object_id(event).should eq("rel_1")
  end

  it "returns nil for events without an object id (e.g. goal.created)" do
    event = id_event("goal.created", %({"goal":"go"}))
    Chronicle::RuntimeReason.maybe_object_id(event).should be_nil
  end

  it "returns nil for payloads without an id (e.g. a JSON array)" do
    event = id_event("object.created", "[1,2,3]")
    Chronicle::RuntimeReason.maybe_object_id(event).should be_nil
  end
end
