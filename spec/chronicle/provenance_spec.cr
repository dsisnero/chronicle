require "../spec_helper"

describe Chronicle::Provenance do
  it "creates provenance with required fields" do
    p = Chronicle::Provenance.new(created_by: "user")
    p.created_by.should eq("user")
    p.caused_by_event.should be_nil
    p.frame_id.should be_nil
  end

  it "GraphObject carries provenance after creation" do
    p = Chronicle::Provenance.new(created_by: "user", caused_by_event: "evt_001")
    obj = Chronicle::GraphObject.new("obj_001", "task", %({}), provenance: p)
    obj.provenance.created_by.should eq("user")
    obj.provenance.caused_by_event.should eq("evt_001")
  end

  it "patch_object auto-applies without explicit proposal" do
    graph = Chronicle::GraphProjection.empty
    graph = graph.apply(make_event("evt_001", "object.created", %({"id":"obj_001","type":"task","data":{}})))

    result = graph.patch_object("obj_001", %({"status":"done"}), actor: "system")
    result.patch.status.should eq(Chronicle::PatchState::Applied)
    result.graph.get_object("obj_001").not_nil!.version.should eq(2)
    result.graph.get_object("obj_001").not_nil!.data.should contain("done")
  end

  it "patch.applied event includes a diff" do
    graph = Chronicle::GraphProjection.empty
    graph = graph.apply(make_event("evt_001", "object.created", %({"id":"obj_001","type":"task","data":{"status":"pending"}})))

    result = graph.patch_object("obj_001", %({"status":"done"}), actor: "system")
    result.diff.should_not be_nil
    result.diff.not_nil!.should contain("status")
  end

  it "patch reject on version mismatch includes rejection_reason" do
    graph = Chronicle::GraphProjection.empty
    graph = graph.apply(make_event("evt_001", "object.created", %({"id":"obj_001","type":"task","data":{}})))

    patch = graph.propose_patch("obj_001", "update", %({"status":"done"}), proposed_by: "user", expected_version: 99)
    graph = graph.apply_patch(patch.id)
    graph.get_patch(patch.id).not_nil!.rejection_reason.not_nil!.should contain("version mismatch")
  end

  it "Provenance carries through from event to object" do
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
      type: "object.created", actor: "user", caused_by: nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"id":"obj_001","type":"task","data":{}}),
    )
    graph = Chronicle::GraphProjection.empty.apply(event)
    obj = graph.get_object("obj_001").not_nil!
    obj.provenance.created_by.should eq("user")
    obj.provenance.caused_by_event.should eq("evt_001")
  end
end

private def make_event(id, type, payload)
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: id,
    type: type, actor: "test", caused_by: nil,
    timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
    payload: payload,
  )
end
