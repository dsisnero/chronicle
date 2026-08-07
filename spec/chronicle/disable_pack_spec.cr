require "../spec_helper"

# `Runtime#disable_pack` — deregistration, not unload (CONTRACT v1.4 #3).
# Ported from activegraph.tests.test_disable_pack: behaviors stop firing
# immediately, tools stop resolving, typed validation reverts to untyped,
# pack-created state stays, re-enable = load_pack (fresh load, not idempotent
# skip), idempotent second disable returns false and emits nothing, unknown
# pack raises PackNotFoundError, and disabling one of two same-short-name
# packs RESOLVES the ambiguity.

module DisablePackCandidate
  include Chronicle::Packs::DSL

  class_property hits : Array(String) = [] of String

  @[Behavior(name: "echo", on: ["goal.created"])]
  def echo(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    DisablePackCandidate.hits << (JSON.parse(event.payload).as_h["goal"].as_s)
    graph.add_object("echo_note", %({"text":"hi"}))
  end

  pack(name: "candidate", version: "1.0.0")
end

private def disable_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

describe Chronicle::Runtime do
  it "disable stops behaviors and tools immediately" do
    DisablePackCandidate.hits = [] of String
    rt = disable_runtime
    rt.load_pack(DisablePackCandidate::PACK)

    rt.run_goal("first")
    DisablePackCandidate.hits.should eq(["first"])

    rt.disable_pack("candidate").should be_true
    rt.run_goal("second")
    DisablePackCandidate.hits.should eq(["first"])
    rt.loaded_packs.should eq([] of String)
  end

  it "disable leaves pack-created state and reverts typed validation to untyped" do
    rt = disable_runtime
    rt.load_pack(DisablePackCandidate::PACK)
    rt.run_goal("go")
    created = rt.graph.not_nil!.objects(type: "echo_note").first

    rt.disable_pack("candidate")
    rt.graph.not_nil!.get_object(created.id).should_not be_nil
    obj = rt.graph.not_nil!.add_object("echo_note", %({"text":"again"}))
    rt.graph.not_nil!.get_object(obj.id).should_not be_nil
  end

  it "disable emits a pack.disabled event and is idempotent" do
    rt = disable_runtime
    rt.load_pack(DisablePackCandidate::PACK)

    rt.disable_pack("candidate").should be_true
    ev = rt.store.iter_events.find { |e| e.type == "pack.disabled" }.not_nil!
    payload = JSON.parse(ev.payload).as_h
    payload["name"].as_s.should eq("candidate")
    payload["behaviors"].as_a.map(&.as_s).should eq(["candidate.echo"])
    payload["object_types"].as_a.map(&.as_s).should eq([] of String)

    rt.disable_pack("candidate").should be_false
    rt.store.iter_events.count { |e| e.type == "pack.disabled" }.should eq(1)
  end

  it "disable of an unknown pack is loud" do
    rt = disable_runtime
    expect_raises(Chronicle::Packs::PackNotFoundError) { rt.disable_pack("never_loaded") }
  end

  it "re-loading a disabled pack re-enables it (fresh load, not idempotent skip)" do
    DisablePackCandidate.hits = [] of String
    rt = disable_runtime
    rt.load_pack(DisablePackCandidate::PACK)
    rt.disable_pack("candidate")

    rt.load_pack(DisablePackCandidate::PACK).should be_true
    rt.run_goal("after re-enable")
    DisablePackCandidate.hits.should eq(["after re-enable"])
    rt.disable_pack("candidate").should be_true
  end

  it "disable resolves a short-name ambiguity to the surviving pack" do
    mk = ->(pack_name : String) {
      Chronicle::Packs::Pack.new(
        name: pack_name, version: "1.0.0",
        behaviors: [Chronicle::Packs::PackBehavior.new(name: "worker")],
      )
    }
    rt = disable_runtime
    rt.load_pack(mk.call("alpha"))
    rt.load_pack(mk.call("beta"))
    expect_raises(Chronicle::Packs::AmbiguousBehaviorError) { rt.get_behavior("worker") }

    rt.disable_pack("alpha")
    rt.get_behavior("worker").name.should eq("beta.worker")
  end
end
