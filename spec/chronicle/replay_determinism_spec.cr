require "../spec_helper"

# Replay determinism acceptance gate: the same event log must reproduce the
# same projection and the same routing decisions. Routing is pure/deterministic
# (smista-style precedence, tie-breaks, privacy, fallback narrowing) and every
# decision is recorded as a `routing.decided` receipt before the model request.
# Running the same prompt against the same policy twice must produce
# byte-identical receipts, and replaying a recorded log must rebuild the same
# projection.

class ReplayMockModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Mock response")
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

private alias ReplayTarget = Chronicle::Routing::Target

private def replay_runtime(store : Chronicle::MemoryEventStore, policy : Chronicle::Routing::Policy) : Chronicle::Runtime(ReplayMockModel)
  agent = Crig::Agent(ReplayMockModel).new(model: ReplayMockModel.new)
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  Chronicle::Runtime(ReplayMockModel).new(store: store, log_agent: Chronicle::LogAgent(ReplayMockModel).new(agent, store: store), policy: policy, graph: graph)
end

private def replay_policy : Chronicle::Routing::Policy
  primary = ReplayTarget.new("deepseek", "deepseek-v4-flash")
  fallback = ReplayTarget.new("local", "local-model")
  Chronicle::Routing::Policy.new(default_target: primary, default_fallbacks: [fallback] of ReplayTarget)
end

private def replay_receipts(store : Chronicle::EventStore) : Array(String)
  store.iter_events.select { |e| e.type == "routing.decided" }.map(&.canonical_json).sort
end

describe Chronicle::Runtime do
  it "produces byte-identical routing decisions for the same prompt and policy" do
    policy = replay_policy
    rt1 = replay_runtime(Chronicle::MemoryEventStore.new, policy)
    rt2 = replay_runtime(Chronicle::MemoryEventStore.new, policy)
    rt1.run("Same routed prompt")
    rt2.run("Same routed prompt")

    replay_receipts(rt1.store).should eq(replay_receipts(rt2.store))
  end

  it "replaying a recorded log rebuilds the identical projection" do
    store = Chronicle::MemoryEventStore.new
    rt = replay_runtime(store, replay_policy)
    rt.run("Replay me")

    replayed = Chronicle::GraphProjection.replay(store.iter_events)
    original = rt.graph.not_nil!
    replayed.all_objects.map(&.to_json).sort.should eq(original.all_objects.map(&.to_json).sort)
    replayed.all_relations.map(&.to_json).sort.should eq(original.all_relations.map(&.to_json).sort)
  end
end
