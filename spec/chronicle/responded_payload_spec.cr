require "../spec_helper"

# Success-path llm.responded payload carries cache_hit + latency_seconds
# (upstream `_emit_llm_event("llm.responded", turn_response.to_dict() | {...})`
# where LLMResponse.to_dict includes cache_hit + latency_seconds). The CONTRACT
# #18 trace line reads them, so a cache-hit responded renders `cache_hit=true`
# and omits cost/latency. Ported from activegraph tests/test_llm_trace.py
# `test_trace_marks_cache_hit_lines`. Divergence: cost_usd stays at the
# provider boundary (Crig seam exposes no cost) — cache_hit and latency are
# runtime-measurable and recorded.

module RespondedPayloadModel
  class Scripted
    include Crig::Completion::CompletionModel

    class_property call_count = 0

    def completion(request : Crig::Completion::Request::CompletionRequest)
      self.class.call_count += 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("ok")
        ),
        Crig::Completion::Usage.new(input_tokens: 7, output_tokens: 3),
        "raw",
        "msg_responded",
      )
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "not implemented in test"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end
end

module RespondedPayloadPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "ex", on: ["object.created"], where: {"type" => "document"})]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    # no-op
  end

  pack(name: "respondedpayload", version: "0.1.0")
end

private def responded_runtime(cache : Chronicle::LLMCache? = nil) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(RespondedPayloadModel::Scripted)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(RespondedPayloadModel::Scripted).new(model: RespondedPayloadModel::Scripted.new, preamble: "")
  la = Chronicle::LogAgent(RespondedPayloadModel::Scripted).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(
    Chronicle::FixedModelExecutor(RespondedPayloadModel::Scripted).new(RespondedPayloadModel::Scripted.new),
  )
  rt = Chronicle::Runtime(RespondedPayloadModel::Scripted).new(
    store: store, log_agent: la, graph: graph, model_effect_worker: worker, llm_cache: cache,
  )
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "records cache_hit and latency_seconds on the live llm.responded payload" do
    store, graph, rt = responded_runtime
    rt.load_pack(RespondedPayloadPack::PACK)
    graph.add_object("document", %({"title":"t"}))
    rt.run_until_idle

    responded = store.iter_events.to_a.find! { |e| e.type == "llm.responded" }
    payload = JSON.parse(responded.payload).as_h
    payload["input_tokens"].as_i.should eq(7)
    payload["output_tokens"].as_i.should eq(3)
    payload["cache_hit"].as_bool.should be_false
    payload["latency_seconds"].as_f?.should_not be_nil
  end

  it "records cache_hit=true on a cache-served llm.responded and renders the trace line without cost/latency" do
    RespondedPayloadModel::Scripted.call_count = 0
    store, graph, rt = responded_runtime
    rt.load_pack(RespondedPayloadPack::PACK)
    graph.add_object("document", %({"title":"t"}))
    rt.run_until_idle
    RespondedPayloadModel::Scripted.call_count.should eq(1)

    cache = Chronicle::LLMCache.from_events(store.iter_events)
    store2, graph2, rt2 = responded_runtime(cache)
    rt2.load_pack(RespondedPayloadPack::PACK)
    graph2.add_object("document", %({"title":"t"}))
    rt2.run_until_idle
    RespondedPayloadModel::Scripted.call_count.should eq(1)

    responded2 = store2.iter_events.to_a.find! { |e| e.type == "llm.responded" }
    JSON.parse(responded2.payload).as_h["cache_hit"].as_bool.should be_true

    line = Chronicle::Trace.format_event(responded2)
    line.should contain("llm.responded")
    line.should contain("cache_hit=true")
    line.should_not contain("cost=$")
    line.should_not contain("latency=")
  end
end
