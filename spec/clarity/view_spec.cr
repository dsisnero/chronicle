require "../spec_helper"

private def make_object_event(id, type)
  Clarity::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: "evt_#{id}",
    type: "object.created", actor: "test", caused_by: nil,
    timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
    payload: %({"id":"#{id}","type":"#{type}","data":{}}),
  )
end

describe Clarity::View do
  it "full view contains all objects" do
    graph = Clarity::GraphProjection.empty
      .apply(make_object_event("obj_001", "task"))
      .apply(make_object_event("obj_002", "claim"))

    view = graph.build_view(Clarity::ViewSpec.new)
    view.objects.size.should eq(2)
  end

  it "filters objects by type" do
    graph = Clarity::GraphProjection.empty
      .apply(make_object_event("obj_001", "task"))
      .apply(make_object_event("obj_002", "claim"))
      .apply(make_object_event("obj_003", "task"))

    spec = Clarity::ViewSpec.new(include_types: ["task"])
    view = graph.build_view(spec)
    view.objects.size.should eq(2)
    view.objects.all? { |o| o.type == "task" }.should be_true
  end

  it "filters objects by type and relations are included" do
    graph = Clarity::GraphProjection.empty
      .apply(make_object_event("obj_001", "task"))
      .apply(make_object_event("obj_002", "claim"))

    spec = Clarity::ViewSpec.new(include_types: ["claim"])
    view = graph.build_view(spec)
    view.objects.size.should eq(1)
    view.objects.first.id.should eq("obj_002")
    view.relations.should be_empty
  end

  it "limits recent events" do
    events = (1..5).map { |i| make_object_event("obj_00#{i}", "task") }
    graph = events.reduce(Clarity::GraphProjection.empty) { |g, e| g.apply(e) }

    spec = Clarity::ViewSpec.new(recent_events: 3)
    view = graph.build_view(spec)
    view.events.size.should eq(3)
  end

  it "filters objects anchored around a specific object" do
    graph = Clarity::GraphProjection.empty
      .apply(make_object_event("obj_001", "task"))
      .apply(make_object_event("obj_002", "claim"))

    spec = Clarity::ViewSpec.new(around: "obj_001", include_types: ["task"])
    view = graph.build_view(spec)
    view.objects.size.should eq(1)
    view.objects.first.id.should eq("obj_001")
  end
end
