require "../spec_helper"

# `Runtime#export_trace` groups events by frame: alongside the flat `events`
# array, a `frames` object maps each frame_id to its events (in log order).
# Events without a frame_id are not grouped. Chronicle-specific enhancement
# over activegraph's trace export (upstream lists all events flatly; the
# `events_in_frame` surface already groups them).

module TraceFramesHelper
  extend self

  def event(seq : UInt64, id : String, frame_id : String?) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: id,
      type: "object.created", actor: "test", caused_by: nil,
      frame_id: frame_id, timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"id":"obj_#{seq}","type":"task","data":{}}),
    )
  end
end

private def trace_frames_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

describe Chronicle::Runtime do
  it "export_trace groups events by frame" do
    rt = trace_frames_runtime
    rt.store.append(TraceFramesHelper.event(1_u64, "evt_1", nil))
    rt.store.append(TraceFramesHelper.event(2_u64, "evt_2", "frame_a"))
    rt.store.append(TraceFramesHelper.event(3_u64, "evt_3", "frame_a"))
    rt.store.append(TraceFramesHelper.event(4_u64, "evt_4", "frame_b"))

    parsed = JSON.parse(rt.export_trace).as_h
    frames = parsed["frames"].as_h
    frames["frame_a"].as_a.map { |e| e["id"].as_s }.should eq(["evt_2", "evt_3"])
    frames["frame_b"].as_a.map { |e| e["id"].as_s }.should eq(["evt_4"])
    frames.has_key?("frame_a").should be_true
    # The flat list is preserved for backward compatibility.
    parsed["events"].as_a.map { |e| e["id"].as_s }.should eq(["evt_1", "evt_2", "evt_3", "evt_4"])
  end

  it "export_trace omits frames when no event carries a frame_id" do
    rt = trace_frames_runtime
    rt.store.append(TraceFramesHelper.event(1_u64, "evt_1", nil))
    rt.store.append(TraceFramesHelper.event(2_u64, "evt_2", nil))

    parsed = JSON.parse(rt.export_trace).as_h
    frames = parsed["frames"]?.try(&.as_h?) || {} of String => JSON::Any
    frames.should be_empty
  end
end
