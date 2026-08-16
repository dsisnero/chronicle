require "../spec_helper"

# Same-target LLM retry loop in the LLM-behavior path. Ported from activegraph
# tests/test_llm_failure.py:
#   - test_transient_llm_network_error_retries_before_handler_runs
#   - test_transient_llm_network_error_exhausts_after_max_attempts
#
# A transient provider failure is retried IN PLACE (same target) up to
# llm_retry_max_attempts before the terminal behavior.failed is emitted — the
# handler never sees the failed attempt's output, and provenance points at the
# request whose response actually fed the handler.
#
# Divergence: Chronicle records each failed attempt as a separate `llm.failed`
# event; upstream folds provider failures into `llm.responded` `{error, ...}`
# payloads via `_emit_llm_error_response` (the llm.responded error-shape parity
# is a separate pending item). The requested-payload retry fields
# (attempt_index / max_attempts / retry_of) and the behavior.failed
# attempts / max_attempts / retry_exhausted extras match upstream.

class FlakyThenSucceedsModel
  include Crig::Completion::CompletionModel

  getter calls : Int32 = 0

  def initialize(@failures : Int32)
  end

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    if @calls <= @failures
      raise Chronicle::RetryableProviderError.new("temporary provider failure")
    end
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("recovered")
      ),
      Crig::Completion::Usage.new(input_tokens: 10, output_tokens: 5),
      "raw",
      "msg_retry",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module RetryLoopPack
  include Chronicle::Packs::DSL

  class_property claim_created : Bool = false
  class_property claim_text : String? = nil

  @[LLMBehavior(name: "extractor", on: ["object.created"], where: {"type" => "document"})]
  def extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    graph.add_object("claim", %({"text":"recovered"}))
    RetryLoopPack.claim_created = true
    RetryLoopPack.claim_text = output
  end

  pack(name: "retryloop", version: "0.1.0")
end

module RetryLoopSpecHelper
  extend self

  # Builds a runtime whose LLM-behavior path uses the given flaky model with
  # the given retry configuration. Mirrors the construction in
  # llm_network_error_spec.cr.
  def runtime(model : FlakyThenSucceedsModel, *, max_attempts : Int32, initial_delay : Float64)
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(FlakyThenSucceedsModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(FlakyThenSucceedsModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(
      Chronicle::FixedModelExecutor(FlakyThenSucceedsModel).new(model),
    )
    rt = Chronicle::Runtime(FlakyThenSucceedsModel).new(
      store: store,
      log_agent: la,
      graph: graph,
      model_effect_worker: worker,
      llm_retry_max_attempts: max_attempts,
      llm_retry_initial_delay_seconds: initial_delay,
    )
    {store, graph, rt}
  end
end

describe Chronicle::Runtime do
  it "retries a transient provider failure before running the handler" do
    RetryLoopPack.claim_created = false
    RetryLoopPack.claim_text = nil
    store, graph, rt = RetryLoopSpecHelper.runtime(
      FlakyThenSucceedsModel.new(failures: 1),
      max_attempts: 3,
      initial_delay: 0.0,
    )
    rt.load_pack(RetryLoopPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    store.iter_events.any? { |e| e.type == "behavior.failed" }.should be_false
    RetryLoopPack.claim_created.should be_true
    RetryLoopPack.claim_text.should eq("recovered")

    events = store.iter_events.to_a
    requests = events.select { |e| e.type == "llm.requested" }
    failures = events.select { |e| e.type == "llm.failed" }
    responded = events.select { |e| e.type == "llm.responded" }

    requests.size.should eq(2)
    failures.size.should eq(1)
    responded.size.should eq(1)

    first_request = JSON.parse(requests[0].payload).as_h
    first_request["attempt_index"]?.should be_nil
    second_request = JSON.parse(requests[1].payload).as_h
    second_request["attempt_index"].as_i.should eq(1)
    second_request["max_attempts"].as_i.should eq(3)
    second_request["retry_of"].as_s.should eq(requests[0].id)

    failures[0].caused_by.should eq(requests[0].id)
    JSON.parse(failures[0].payload).as_h["retryable"].as_bool.should be_true

    responded[0].caused_by.should eq(requests[1].id)
  end

  it "exhausts retries and emits behavior.failed with retry_exhausted extras" do
    RetryLoopPack.claim_created = false
    store, graph, rt = RetryLoopSpecHelper.runtime(
      FlakyThenSucceedsModel.new(failures: 99),
      max_attempts: 2,
      initial_delay: 0.0,
    )
    rt.load_pack(RetryLoopPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    RetryLoopPack.claim_created.should be_false

    events = store.iter_events.to_a
    requests = events.select { |e| e.type == "llm.requested" }
    failures = events.select { |e| e.type == "llm.failed" }
    requests.size.should eq(2)
    failures.size.should eq(2)

    second_request = JSON.parse(requests[1].payload).as_h
    second_request["attempt_index"].as_i.should eq(1)
    second_request["max_attempts"].as_i.should eq(2)
    second_request["retry_of"].as_s.should eq(requests[0].id)

    failed = events.find! { |e| e.type == "behavior.failed" }
    payload = JSON.parse(failed.payload).as_h
    payload["behavior"].as_s.should eq("retryloop.extractor")
    payload["reason"].as_s.should eq("llm.network_error")
    payload["attempts"].as_i.should eq(2)
    payload["max_attempts"].as_i.should eq(2)
    payload["retry_exhausted"].as_bool.should be_true
  end
end
