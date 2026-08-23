require "../spec_helper"

# Provenance stamping for objects created inside an @llm_behavior handler.
# Ported from activegraph runtime/behavior_graph.py + runtime.py
# (`bgraph._llm_request_event_id` / `bgraph._tool_request_event_ids`,
# CONTRACT v0.6 #15, v0.7 #19): every object/relation the handler creates
# carries the successful llm.requested event id and the tool.requested event
# ids in its provenance, so causal_chain can weave the LLM/tool round-trips.

module StampPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "stamper", on: ["object.created"], where: {"type" => "document"})]
  def stamper(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    graph.add_object("claim", %({"text":#{output.to_json}}))
  end

  pack(name: "stamppack", version: "0.1.0")
end

module StampToolPack
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "tooler", on: ["object.created"], where: {"type" => "document"}, tools: ["probe"])]
  def tooler(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    graph.add_object("claim", %({"text":#{output.to_json}}))
  end

  @[Tool(name: "probe", description: "p")]
  def probe(args : String) : String
    JSON.build do |json|
      json.object do
        json.field "ok", true
      end
    end
  end

  pack(name: "stamptool", version: "0.1.0")
end

module StampToolModel
  class Scripted
    include Crig::Completion::CompletionModel

    class_property call_count = 0

    def completion(request : Crig::Completion::Request::CompletionRequest)
      self.class.call_count += 1
      if self.class.call_count == 1
        Crig::Completion::CompletionResponse(String).new(
          Crig::OneOrMany(Crig::Completion::AssistantContent).one(
            Crig::Completion::AssistantContent.tool_call("c1", "stamptool.probe", JSON.parse(%({"q":"1"})))
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
          Crig::Completion::Usage.new(input_tokens: 4, output_tokens: 2),
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
end

module StampModel
  class Scripted
    include Crig::Completion::CompletionModel

    def completion(request : Crig::Completion::Request::CompletionRequest)
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("Sample claim")
        ),
        Crig::Completion::Usage.new(input_tokens: 4, output_tokens: 2),
        "raw",
        "msg_behavior",
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

private def stamp_runtime(model : StampModel::Scripted, pack)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(StampModel::Scripted).new(model: model, preamble: "")
  la = Chronicle::LogAgent(StampModel::Scripted).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(StampModel::Scripted).new(model))
  rt = Chronicle::Runtime(StampModel::Scripted).new(
    store: store, log_agent: la, graph: graph, model_effect_worker: worker,
  )
  rt.load_pack(pack)
  {store, graph, rt}
end

private def stamp_tool_runtime(model : StampToolModel::Scripted, pack)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(StampToolModel::Scripted).new(model: model, preamble: "")
  la = Chronicle::LogAgent(StampToolModel::Scripted).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(StampToolModel::Scripted).new(model))
  rt = Chronicle::Runtime(StampToolModel::Scripted).new(
    store: store, log_agent: la, graph: graph, model_effect_worker: worker,
  )
  rt.load_pack(pack)
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "stamps llm_request_event_id on objects created inside an LLM handler" do
    store, graph, rt = stamp_runtime(StampModel::Scripted.new, StampPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    req = store.iter_events.to_a.find! { |e| e.type == "llm.requested" }
    claim = graph.all_objects.find! { |o| o.type == "claim" }
    claim.provenance.llm_request_event_id.should eq(req.id)
    claim.provenance.tool_request_event_ids.should be_nil
  end

  it "stamps tool_request_event_ids when the LLM turn loop invoked tools" do
    StampToolModel::Scripted.call_count = 0
    store, graph, rt = stamp_tool_runtime(StampToolModel::Scripted.new, StampToolPack::PACK)
    graph.add_object("document", %({"title":"hello"}))
    rt.run_until_idle

    claim = graph.all_objects.find! { |o| o.type == "claim" }
    claim.provenance.llm_request_event_id.should_not be_nil
    request_ids = claim.provenance.tool_request_event_ids.not_nil!
    request_ids.size.should eq(1)
    tool_req = store.iter_events.to_a.find! { |e| e.type == "tool.requested" }
    request_ids.first.should eq(tool_req.id)
  end
end
