require "../spec_helper"

# `llm.failed` error-shape parity: upstream folds provider failures into an
# `llm.responded` payload via `_emit_llm_error_response` carrying
# `{behavior, prompt_hash, model, error: {reason, message, **extras},
# cache_hit, retryable, attempt_index, max_attempts, latency_seconds,
# cost_usd: "0"}`. Chronicle records failed attempts as a separate
# `llm.failed` event (naming divergence), so the port aligns the SHAPE: each
# `llm.failed` carries the same error object / retryable / attempt fields /
# cost_usd / cache_hit surface. Ported from activegraph runtime.py
# `_emit_llm_error_response` + tests/test_llm_failure.py
# test_transient_llm_network_error_retries_before_handler_runs and
# test_schema_violation_becomes_behavior_failed.

class ErrorShapeFlakyModel
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

class ErrorShapeSchemaModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    raise Chronicle::LLMBehaviorError.new(
      "llm.schema_violation",
      "no claims field",
      {
        "raw_text" => JSON::Any.new(%({"oops": 1})),
        "schema"   => JSON::Any.new("ClaimList"),
      },
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module ErrorShapePack
  include Chronicle::Packs::DSL

  class_property claim_created : Bool = false

  @[LLMBehavior(name: "extractor", on: ["object.created"], where: {"type" => "document"})]
  def extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    graph.add_object("claim", %({"text":"recovered"}))
    ErrorShapePack.claim_created = true
  end

  pack(name: "errorshape", version: "0.1.0")
end

module ErrorShapeSpecHelper
  extend self

  def runtime(model : ErrorShapeFlakyModel) : {Chronicle::MemoryEventStore, Chronicle::Runtime(ErrorShapeFlakyModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(ErrorShapeFlakyModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(ErrorShapeFlakyModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(
      Chronicle::FixedModelExecutor(ErrorShapeFlakyModel).new(model),
    )
    rt = Chronicle::Runtime(ErrorShapeFlakyModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
      llm_retry_max_attempts: 2, llm_retry_initial_delay_seconds: 0.0,
    )
    rt.load_pack(ErrorShapePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    {store, rt}
  end

  def runtime(model : ErrorShapeSchemaModel) : {Chronicle::MemoryEventStore, Chronicle::Runtime(ErrorShapeSchemaModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(ErrorShapeSchemaModel).new(model: model, preamble: "")
    la = Chronicle::LogAgent(ErrorShapeSchemaModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(
      Chronicle::FixedModelExecutor(ErrorShapeSchemaModel).new(model),
    )
    rt = Chronicle::Runtime(ErrorShapeSchemaModel).new(
      store: store, log_agent: la, graph: graph, model_effect_worker: worker,
      llm_retry_initial_delay_seconds: 0.0,
    )
    rt.load_pack(ErrorShapePack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    {store, rt}
  end
end

describe Chronicle::Runtime do
  it "records a failed retry attempt with the upstream llm error shape" do
    ErrorShapePack.claim_created = false
    store, rt = ErrorShapeSpecHelper.runtime(ErrorShapeFlakyModel.new(failures: 1))
    rt.run_until_idle

    events = store.iter_events.to_a
    requests = events.select { |e| e.type == "llm.requested" }
    failures = events.select { |e| e.type == "llm.failed" }
    failures.size.should eq(1)

    failed = failures[0]
    failed.caused_by.should eq(requests[0].id)
    payload = JSON.parse(failed.payload).as_h

    error = payload["error"].as_h
    error["reason"].as_s.should eq("llm.network_error")
    # Provider exception text is redacted from the log; only the class name
    # rides the generic-failure message.
    error["message"].as_s.should eq("Chronicle::RetryableProviderError")
    error["model"].as_s.should eq("default")

    payload["retryable"].as_bool.should be_true
    payload["attempt_index"].as_i.should eq(0)
    payload["max_attempts"].as_i.should eq(2)
    payload["cost_usd"].as_s.should eq("0")
    payload["cache_hit"].as_bool.should be_false
    payload["behavior"].as_s.should eq("errorshape.extractor")
    payload["prompt_hash"].as_s.should_not be_empty
    payload["model"].as_s.should eq("default")
    payload["latency_seconds"].as_f?.should_not be_nil
  end

  it "carries a structured failure reason and payload extras in the llm error object" do
    ErrorShapePack.claim_created = false
    store, rt = ErrorShapeSpecHelper.runtime(ErrorShapeSchemaModel.new)
    rt.run_until_idle

    events = store.iter_events.to_a
    failures = events.select { |e| e.type == "llm.failed" }
    failures.size.should eq(1)

    payload = JSON.parse(failures[0].payload).as_h
    error = payload["error"].as_h
    error["reason"].as_s.should eq("llm.schema_violation")
    error["message"].as_s.should contain("no claims field")
    error["raw_text"].as_s.should eq(%({"oops": 1}))
    error["schema"].as_s.should eq("ClaimList")
    payload["retryable"].as_bool.should be_false
    payload["cost_usd"].as_s.should eq("0")

    failed_behavior = events.find! { |e| e.type == "behavior.failed" }
    JSON.parse(failed_behavior.payload).as_h["reason"].as_s.should eq("llm.schema_violation")
  end
end
