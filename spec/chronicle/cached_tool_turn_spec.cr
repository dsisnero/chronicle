require "../spec_helper"

# v1.0.3 #4 recorded-provider roundtrip for the LLM cache. Ported from
# activegraph tests/test_v1_0_3_tool_multiturn.py: a tool-using turn cached as
# an llm.responded event must reconstruct its tool calls on replay. Without
# this, a replayed multi-turn tool loop loses the tool dispatch — the second
# turn's prompt hash differs from the live one and the replay silently serves
# a text-only response with no tools.

class CachedToolScriptedModel
  include Crig::Completion::CompletionModel

  class_property call_count = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    self.class.call_count += 1
    case self.class.call_count
    when 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.tool_call("c1", "cachedtool.my_tool", JSON.parse(%({"q":"x"})))
        ),
        Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
        "raw",
        "msg_c1",
      )
    else
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("done")
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_final",
      )
    end
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

class CachedToolExplodingModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    raise "model must not be called when the tool-call turn is served from cache"
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "model must not be called when the tool-call turn is served from cache"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module CachedToolTurnPack
  include Chronicle::Packs::DSL

  class_property captured_output : String? = nil
  class_property invoked : Bool = false

  @[LLMBehavior(name: "ex", on: ["object.created"], tools: ["my_tool"])]
  def ex(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    CachedToolTurnPack.captured_output = output
  end

  @[Tool(name: "my_tool", description: "t")]
  def my_tool(args : String) : String
    CachedToolTurnPack.invoked = true
    JSON.build do |json|
      json.object do
        json.field "answer", args
      end
    end
  end

  pack(name: "cachedtool", version: "0.1.0")
end

describe Chronicle::Runtime do
  it "round-trips a tool-call turn through the LLM cache so replay re-dispatches the tool" do
    CachedToolTurnPack.captured_output = nil
    CachedToolTurnPack.invoked = false
    CachedToolScriptedModel.call_count = 0

    # First runtime: live model returns a tool call then the final text. The
    # tool-call turn gets cached under its prompt hash.
    cache = Chronicle::LLMCache.new
    recording_store = Chronicle::MemoryEventStore.new
    recording_graph = Chronicle::GraphProjection.empty.attach_store(recording_store)
    recording_model = CachedToolScriptedModel.new
    recording_agent = Crig::Agent(CachedToolScriptedModel).new(model: recording_model, preamble: "")
    recording_la = Chronicle::LogAgent(CachedToolScriptedModel).new(recording_agent, store: recording_store, max_turns: 1)
    recording_worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(CachedToolScriptedModel).new(recording_model))
    recording_rt = Chronicle::Runtime(CachedToolScriptedModel).new(
      store: recording_store, log_agent: recording_la, graph: recording_graph,
      model_effect_worker: recording_worker, llm_cache: cache,
    )
    recording_rt.load_pack(CachedToolTurnPack::PACK)
    recording_graph.add_object("document", %({"title":"hello"}))
    recording_rt.run_until_idle
    CachedToolTurnPack.invoked.should be_true

    # Replay runtime: the model raises if called, so the tool-call turn must be
    # served entirely from cache with its tool call intact.
    replay_store = Chronicle::MemoryEventStore.new
    replay_graph = Chronicle::GraphProjection.empty.attach_store(replay_store)
    replay_model = CachedToolExplodingModel.new
    replay_agent = Crig::Agent(CachedToolExplodingModel).new(model: replay_model, preamble: "")
    replay_la = Chronicle::LogAgent(CachedToolExplodingModel).new(replay_agent, store: replay_store, max_turns: 1)
    replay_worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(CachedToolExplodingModel).new(replay_model))
    replay_rt = Chronicle::Runtime(CachedToolExplodingModel).new(
      store: replay_store, log_agent: replay_la, graph: replay_graph,
      model_effect_worker: replay_worker, llm_cache: cache,
    )
    replay_rt.load_pack(CachedToolTurnPack::PACK)
    replay_graph.add_object("document", %({"title":"hello"}))
    replay_rt.run_until_idle

    replay_store.iter_events.any? { |e| e.type == "tool.responded" }.should be_true
    replay_store.iter_events.any? { |e| e.type == "behavior.completed" }.should be_true
  end
end
