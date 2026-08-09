require "../spec_helper"

module ContextMethodPacks
  module ProposerPack
    include Chronicle::Packs::DSL

    @[ObjectType(name: "note")]
    struct Note
      include JSON::Serializable

      getter title : String
    end

    @[ObjectType(name: "doc")]
    struct Doc
      include JSON::Serializable

      getter title : String
    end

    @[Behavior(name: "proposer", on: ["object.created"], where: {"type" => "note"})]
    def proposer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      payload = JSON.parse(event.payload).as_h
      note_id = payload["id"]?.try(&.as_s) || "?"
      ctx.propose_object("doc", %({"title":"draft for #{note_id}"}), reason: "legacy scenario")
    end

    pack(
      name: "ctxproposer",
      version: "0.1.0",
      policies: [
        Chronicle::Packs::PackPolicy.new(name: "gate_docs", requires_approval: ["doc"]),
      ],
    )
  end
end

private def context_methods_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  rt.load_pack(ContextMethodPacks::ProposerPack::PACK)
  {store, graph, rt}
end

describe Chronicle::RuntimeContextRequiredError do
  it "is an ExecutionError with a doc URL" do
    error = Chronicle::RuntimeContextRequiredError.new(method: "ctx.propose_object")
    (error.is_a?(Chronicle::ExecutionError)).should be_true
    error.to_s.should contain("requires a runtime-bound context")
    error.doc_url.should end_with("/errors/runtime-context-required-error")
  end
end

describe Chronicle::Packs::BehaviorContext do
  it "raises RuntimeContextRequiredError when propose_object is called without a runtime" do
    provider = ->(name : String) : Hash(String, JSON::Any)? { nil }
    ctx = Chronicle::Packs::BehaviorContext.new("pack", {} of String => JSON::Any, provider)
    error = expect_raises(Chronicle::RuntimeContextRequiredError) do
      ctx.propose_object("doc", %({"title":"x"}))
    end
    error.to_s.should contain("ctx.propose_object")
  end
end

describe Chronicle::Runtime do
  it "ctx.propose_object defers a gated object behind approval, approve_pack materializes it" do
    store, graph, rt = context_methods_runtime
    graph.add_object("note", %({"title":"n"}))
    rt.run_until_idle

    # The proposer behavior fired and routed a gated doc through approval.
    approvals = rt.pack_pending_approvals
    approvals.size.should eq(1)
    approval = approvals.first
    approval.object_type.should eq("doc")
    JSON.parse(approval.data)["title"].as_s.should eq("draft for note#1")
    graph.objects(type: "doc").should be_empty

    materialized = rt.approve_pack(approval.id)
    materialized.type.should eq("doc")
    graph.objects(type: "doc").size.should eq(1)
  end
end
