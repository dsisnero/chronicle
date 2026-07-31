require "../spec_helper"

# Frames wiring specs: frame_id on the event envelope, codec round-trip, and
# Runtime push/pop frame lifecycle. Ported from activegraph frame.py + CONTRACT
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

class FrameModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Frame done")
      ),
      Crig::Completion::Usage.new(input_tokens: 2, output_tokens: 2),
      "raw",
      "msg_1",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module FramesSpecHelper
  extend self

  def runtime : Clarity::Runtime(FrameModel)
    store = Clarity::MemoryEventStore.new
    agent = Crig::Agent(FrameModel).new(model: FrameModel.new)
    la = Clarity::LogAgent(FrameModel).new(agent, store: store)
    Clarity::Runtime(FrameModel).new(store: store, log_agent: la)
  end

  def event(id : String, type : String, frame_id : String?) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: id,
      type: type, actor: "test", caused_by: nil, frame_id: frame_id,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"k":"v"}),
    )
  end
end

describe Clarity::Event do
  it "carries frame_id through the envelope" do
    e = FramesSpecHelper.event("evt_1", "object.created", "frame_1")
    e.frame_id.should eq("frame_1")
    e.canonical_json.should contain("\"frame_id\":\"frame_1\"")
  end
end

describe Clarity::EventLogCodec do
  it "round-trips frame_id through encode/decode" do
    event = FramesSpecHelper.event("evt_1", "object.created", "frame_1")
    log = Clarity::EventLog.from_events([event])
    decoded = Clarity::EventLogCodec.decode(Clarity::EventLogCodec.encode(log))
    decoded.events[0].frame_id.should eq("frame_1")
  end
end

describe Clarity::Runtime do
  it "pushes and pops frames and stamps events with the current frame" do
    runtime = FramesSpecHelper.runtime
    runtime.current_frame_id.should be_nil

    runtime.push_frame(Clarity::Frame.new(goal: "research", id: "frame_1"))
    runtime.current_frame_id.should eq("frame_1")
    runtime.run("Research this")
    runtime.pop_frame

    runtime.current_frame_id.should be_nil
    runtime.events_in_frame("frame_1").any? { |e| e.type == "chat.message" }.should be_true
    runtime.events_in_frame("frame_1").all? { |e| e.frame_id == "frame_1" }.should be_true
  end
end
