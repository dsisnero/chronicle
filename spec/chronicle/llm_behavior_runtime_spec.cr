require "../spec_helper"

# Auto-run of an `@[LLMBehavior]` handler through the native LLM effect
# pipeline. Ported from activegraph tests/test_llm_behavior.py: the runtime's
# `run_until_idle` (no prompt) drains newly created objects through an LLM
# behavior, which emits llm.requested / llm.responded and invokes the handler
# with the model output while the dispatch quiesces.

module LlmBehaviorFixture
  class ScriptedModel
    include Crig::Completion::CompletionModel

    getter calls : Int32 = 0

    def completion(request : Crig::Completion::Request::CompletionRequest)
      @calls += 1
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

module LlmExtractPackDoc
  include Chronicle::Packs::DSL

  class_property captured_output : String? = nil

  @[LLMBehavior(name: "extract", on: ["object.created"])]
  def extract(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    LlmExtractPackDoc.captured_output = output
  end

  pack(name: "llmdoc", version: "0.1.0")
end

module LlmExtractPackEmpty
  include Chronicle::Packs::DSL

  @[LLMBehavior(name: "extract", on: ["object.created"], where: {"type" => "document"})]
  def extract(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
    id = JSON.parse(event.payload)["id"].as_s
    obj = graph.add_object("claim", %({"text":#{output.to_json}}))
    graph.add_relation(obj.id, id, "supports")
  end

  pack(name: "llmctx", version: "0.1.0")
end

module LlmBehaviorSpecHelper
  extend self

  def runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(
      Chronicle::FixedModelExecutor(LlmBehaviorFixture::ScriptedModel).new(LlmBehaviorFixture::ScriptedModel.new),
    )
    rt = Chronicle::Runtime(PackModel).new(
      store: store,
      log_agent: la,
      graph: graph,
      model_effect_worker: worker,
    )
    {store, graph, rt}
  end
end

private def llm_runtime(&)
  store, graph, rt = LlmBehaviorSpecHelper.runtime
  yield store, graph, rt
end

describe "LLM behavior auto-run through the model effect pipeline" do
  it "runs an @[LLMBehavior] handler with the model output and records llm events" do
    LlmExtractPackDoc.captured_output = nil
    llm_runtime do |store, graph, rt|
      rt.load_pack(LlmExtractPackDoc::PACK)
      graph.add_object("document", %({"title":"hello"}))
      rt.run_until_idle

      LlmExtractPackDoc.captured_output.should eq("Sample claim")
      types = store.iter_events.map(&.type)
      types.should contain("llm.requested")
      types.should contain("llm.responded")
      (types.index("llm.requested").not_nil! < types.index("llm.responded").not_nil!).should be_true
      types.should contain("behavior.completed")
    end
  end

  it "chains llm.requested to the triggering event and llm.responded to llm.requested" do
    llm_runtime do |store, graph, rt|
      rt.load_pack(LlmExtractPackDoc::PACK)
      graph.add_object("document", %({"title":"hello"}))
      rt.run_until_idle

      events = store.iter_events.to_a
      req = events.find! { |e| e.type == "llm.requested" }
      resp = events.find! { |e| e.type == "llm.responded" }
      trigger = events.find! { |e| e.type == "object.created" }
      resp.caused_by.should eq(req.id)
      req.caused_by.should eq(trigger.id)
    end
  end

  it "records handler object/relation mutations on behavior.completed" do
    llm_runtime do |store, graph, rt|
      rt.load_pack(LlmExtractPackEmpty::PACK)
      graph.add_object("document", %({"title":"hello"}))
      rt.run_until_idle

      completed = store.iter_events.to_a.find! { |e| e.type == "behavior.completed" }
      payload = JSON.parse(completed.payload)
      payload["objects_created"].as_i.should eq(1)
      payload["relations_created"].as_i.should eq(1)
    end
  end
end
