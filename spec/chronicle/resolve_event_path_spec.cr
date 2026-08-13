require "../spec_helper"

private def path_event(payload : String) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: "evt_1",
    type: "object.created", actor: "user", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

describe Chronicle::RuntimeReason do
  it "resolves event.payload.id through the path expression (upstream _resolve_event_path)" do
    event = path_event(%({"id":"doc#1"}))
    Chronicle::RuntimeReason.resolve_event_path("event.payload.id", event).should eq("doc#1")
  end

  it "resolves nested paths through payload hashes" do
    event = path_event(%({"object":{"id":"obj#2","nested":{"k":1}}}))
    Chronicle::RuntimeReason.resolve_event_path("event.payload.object.id", event).should eq("obj#2")
    Chronicle::RuntimeReason.resolve_event_path("event.payload.object.nested.k", event).should eq(1)
  end

  it "returns nil when the expression does not start with event" do
    event = path_event(%({"id":"doc#1"}))
    Chronicle::RuntimeReason.resolve_event_path("payload.id", event).should be_nil
  end

  it "returns nil for an empty expression" do
    event = path_event(%({"id":"doc#1"}))
    Chronicle::RuntimeReason.resolve_event_path("", event).should be_nil
  end

  it "returns nil when a path segment is missing" do
    event = path_event(%({"id":"doc#1"}))
    Chronicle::RuntimeReason.resolve_event_path("event.payload.missing", event).should be_nil
  end

  it "returns nil when a path segment resolves to null" do
    event = path_event(%({"id":null}))
    Chronicle::RuntimeReason.resolve_event_path("event.payload.id", event).should be_nil
  end
end
