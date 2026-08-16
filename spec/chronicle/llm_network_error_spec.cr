require "../spec_helper"

# LLM provider network failure folding in the LLM-behavior path. Ported from
# activegraph tests/test_llm_failure.py::test_network_error_becomes_behavior_failed_with_reason:
# a provider that raises a network error produces behavior.failed with
# reason="llm.network_error" (upstream `_invoke_llm_body`'s generic-exception
# fold), not a nil reason.

class NetworkErrorModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    raise Crig::Completion::CompletionError.new("ConnectionError: boom", Crig::Completion::CompletionError::Kind::HttpError)
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module NetworkErrorPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "extractor", on: ["object.created"])]
  def extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
  end

  pack(name: "networkerror", version: "0.1.0")
end

describe Chronicle::Runtime do
  it "folds a provider network error into behavior.failed reason llm.network_error" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    model = NetworkErrorModel.new
    agent = Crig::Agent(NetworkErrorModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(NetworkErrorModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(NetworkErrorModel).new(model))
    rt = Chronicle::Runtime(NetworkErrorModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
      llm_retry_initial_delay_seconds: 0.0,
    )
    rt.load_pack(NetworkErrorPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    failed = store.iter_events.find { |e| e.type == "behavior.failed" }.not_nil!
    payload = JSON.parse(failed.payload).as_h
    payload["reason"]?.should eq("llm.network_error")
    store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_false
  end
end
