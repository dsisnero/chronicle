require "../spec_helper"

describe Chronicle::GraphProjection do
  it "proposes a patch on an object" do
    graph = Chronicle::GraphProjection.empty
    event = Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"id":"obj_001","type":"task","data":{}}),
    )
    graph = graph.apply(event)

    patch = graph.propose_patch("obj_001", "update", %({"status":"done"}), proposed_by: "user")
    patch.status.should eq(Chronicle::PatchState::Proposed)
    patch.target.should eq("obj_001")
  end

  it "applies a proposed patch and increments version" do
    graph = Chronicle::GraphProjection.empty
    graph = graph.apply(make_event("evt_001", "object.created", %({"id":"obj_001","type":"task","data":{}})))

    patch = graph.propose_patch("obj_001", "update", %({"status":"done"}), proposed_by: "user")
    graph.get_object("obj_001").not_nil!.version.should eq(1)

    graph = graph.apply_patch(patch.id)
    graph.get_object("obj_001").not_nil!.version.should eq(2)

    stored = graph.get_patch(patch.id)
    stored.should_not be_nil
    stored.not_nil!.status.should eq(Chronicle::PatchState::Applied)
  end

  it "rejects a patch on version mismatch" do
    graph = Chronicle::GraphProjection.empty
    graph = graph.apply(make_event("evt_001", "object.created", %({"id":"obj_001","type":"task","data":{}})))

    patch = graph.propose_patch("obj_001", "update", %({"status":"done"}), proposed_by: "user", expected_version: 99)

    graph = graph.apply_patch(patch.id)
    stored = graph.get_patch(patch.id)
    stored.not_nil!.status.should eq(Chronicle::PatchState::Rejected)
    stored.not_nil!.rejection_reason.not_nil!.should contain("version mismatch")
  end

  it "raises on double-apply of same patch" do
    graph = Chronicle::GraphProjection.empty
    graph = graph.apply(make_event("evt_001", "object.created", %({"id":"obj_001","type":"task","data":{}})))

    patch = graph.propose_patch("obj_001", "update", %({"status":"done"}), proposed_by: "user")
    graph = graph.apply_patch(patch.id)

    expect_raises(Chronicle::GraphProjectionError, /already/) do
      graph.apply_patch(patch.id)
    end
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
