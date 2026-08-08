require "../spec_helper"

# `Runtime#status` — frozen snapshot of the runtime (CONTRACT v0.8 #11).
# Ported from activegraph.runtime.runtime.Runtime#status: run_id, a log-derived
# `state` (idle / exhausted / stopped), the recent-events tail (id/type/actor/
# timestamp summaries), and loaded-behavior info (name/kind/subscribed_to/
# pattern/activate_after). State is log-based so a freshly loaded runtime and
# the runtime that saved the log agree.

class StatusMockModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("ok")
      ),
      Crig::Completion::Usage.new,
      "raw",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module StatusPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "pinger", on: ["goal.created"])]
  def pinger(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # no-op
  end

  pack(name: "statuspack", version: "0.1.0")
end

private def status_runtime : Chronicle::Runtime(StatusMockModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(StatusMockModel).new(model: StatusMockModel.new, preamble: "")
  la = Chronicle::LogAgent(StatusMockModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(StatusMockModel).new(store: store, log_agent: la, graph: graph)
end

describe Chronicle::Runtime do
  it "status reports state idle after a clean run" do
    rt = status_runtime
    rt.run_goal("hello")
    rt.status.state.should eq(Chronicle::RuntimeState::Idle)
  end

  it "status reports state stopped before any run" do
    rt = status_runtime
    rt.status.state.should eq(Chronicle::RuntimeState::Stopped)
  end

  it "status includes the recent-events tail with id/type/actor" do
    rt = status_runtime
    rt.run_goal("hello")

    recent = rt.status.recent_events
    recent.should_not be_empty
    last = recent[-1]
    last.id.should_not be_empty
    last.type.should_not be_empty
    last.actor.should_not be_nil
  end

  it "status lists loaded behaviors with name and subscribed events" do
    rt = status_runtime
    rt.load_pack(StatusPack::PACK)

    behaviors = rt.status.registered_behaviors
    behaviors.any? { |b| b.name == "statuspack.pinger" }.should be_true
    pinger = behaviors.find { |b| b.name == "statuspack.pinger" }.not_nil!
    pinger.subscribed_to.should eq(["goal.created"])
  end

  it "status serializes to the documented JSON schema" do
    rt = status_runtime
    rt.run_goal("hello")

    h = rt.status.to_h
    h.has_key?("run_id").should be_true
    h.has_key?("state").should be_true
    h.has_key?("events_processed").should be_true
    h.has_key?("budget").should be_true
    h.has_key?("registered_behaviors").should be_true
    h.has_key?("recent_events").should be_true
    h["state"].as_s.should eq("idle")
  end

  it "status is a frozen value type supporting copy_with" do
    rt = status_runtime
    rt.run_goal("hello")

    base = rt.status
    modified = base.copy_with(state: Chronicle::RuntimeState::Exhausted)
    modified.state.should eq(Chronicle::RuntimeState::Exhausted)
    base.state.should eq(Chronicle::RuntimeState::Idle)
  end
end
