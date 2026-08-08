require "../spec_helper"

private def read_object(id : String, type : String = "doc") : Chronicle::GraphObject
  Chronicle::GraphObject.new(id: id, type: type, data: %({"n":1}))
end

private def read_view(objects : Array(Chronicle::GraphObject)) : Chronicle::View
  Chronicle::View.new(objects: objects, relations: [] of Chronicle::GraphRelation, events: [] of Chronicle::Event)
end

describe Chronicle::ContextRead::ReadRecorder do
  it "records reads in first-read order, deduplicated" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    recorder.record("doc#1")
    recorder.record("doc#2")
    recorder.record("doc#1")
    recorder.object_ids.should eq(["doc#1", "doc#2"])
  end

  it "records batches in returned order" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    recorder.record_objects([read_object("doc#1"), read_object("doc#2"), read_object("doc#1")])
    recorder.object_ids.should eq(["doc#1", "doc#2"])
  end

  it "exposes size and empty-ness" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    recorder.empty?.should be_true
    recorder.record("doc#1")
    recorder.size.should eq(1)
    recorder.empty?.should be_false
  end

  it "returns a copy of the read set" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    recorder.record("doc#1")
    ids = recorder.object_ids
    ids.clear
    recorder.object_ids.should eq(["doc#1"])
  end
end

describe Chronicle::ContextRead::TracedView do
  it "records the objects each objects() call returns" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    view = read_view([read_object("doc#1"), read_object("doc#2")])
    traced = Chronicle::ContextRead::TracedView.new(view, recorder)

    traced.objects(type: "doc")
    recorder.object_ids.should eq(["doc#1", "doc#2"])
  end

  it "filters by type before recording" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    view = read_view([read_object("doc#1"), read_object("claim#1", "claim")])
    traced = Chronicle::ContextRead::TracedView.new(view, recorder)

    traced.objects(type: "claim")
    recorder.object_ids.should eq(["claim#1"])
  end

  it "does not trace relations() or events() reads" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    traced = Chronicle::ContextRead::TracedView.new(read_view([read_object("doc#1")]), recorder)

    traced.relations
    traced.events
    recorder.object_ids.should be_empty
  end

  it "returns the full object set on an unfiltered call" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    traced = Chronicle::ContextRead::TracedView.new(read_view([read_object("doc#1")]), recorder)

    traced.objects.should eq([read_object("doc#1")])
  end
end

describe Chronicle::ContextRead do
  it "builds a context.read payload with behavior, event ids, object_ids, and count" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    recorder.record("doc#1")
    recorder.record("doc#2")

    payload = Chronicle::ContextRead.context_read_payload(
      behavior_name: "reader",
      event_id: "evt_000001",
      execution_event_id: "evt_000002",
      recorder: recorder,
    )
    payload["behavior"].as_s.should eq("reader")
    payload["event_id"].as_s.should eq("evt_000001")
    payload["execution_event_id"].as_s.should eq("evt_000002")
    payload["object_ids"].as_a.map(&.as_s).should eq(["doc#1", "doc#2"])
    payload["count"].as_i.should eq(2)
    payload.has_key?("truncated").should be_false
  end

  it "caps object_ids at CONTEXT_READ_ID_CAP but keeps count exact" do
    recorder = Chronicle::ContextRead::ReadRecorder.new
    (1..(Chronicle::ContextRead::CONTEXT_READ_ID_CAP + 50)).each do |i|
      recorder.record("doc##{i}")
    end

    payload = Chronicle::ContextRead.context_read_payload(
      behavior_name: "reader",
      event_id: "evt_1",
      execution_event_id: "evt_2",
      recorder: recorder,
    )
    payload["object_ids"].as_a.size.should eq(Chronicle::ContextRead::CONTEXT_READ_ID_CAP)
    payload["count"].as_i.should eq(Chronicle::ContextRead::CONTEXT_READ_ID_CAP + 50)
    payload["truncated"].as_bool.should be_true
    payload["object_ids"].as_a.first.as_s.should eq("doc#1")
    payload["object_ids"].as_a.last.as_s.should eq("doc##{Chronicle::ContextRead::CONTEXT_READ_ID_CAP}")
  end
end
