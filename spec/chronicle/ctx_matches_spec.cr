require "../spec_helper"

# ctx.matches pattern bindings (CONTRACT v0.7 #12): a pattern-based behavior
# fires ONCE per event regardless of how many bindings the pattern produced,
# and `ctx.matches` carries the bindings (each with node/rel names → ids) for
# the developer to iterate. Ported from activegraph tests/test_pattern_subscriptions.py.

module CtxMatchesPack
  include Chronicle::Packs::DSL

  class_property captured : Array(Hash(String, String)) = [] of Hash(String, String)
  class_property fired_counts : Array(Int32) = [] of Int32

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    a = graph.add_object("claim", %({"text":"A","confidence":0.9}))
    b = graph.add_object("claim", %({"text":"B","confidence":0.9}))
    graph.add_relation(a.id, b.id, "contradicts")
  end

  @[Behavior(
    name: "critic",
    on: ["relation.created"],
    where: {"type" => "contradicts"},
    pattern: "(c1:claim)-[r:contradicts]->(c2:claim)",
  )]
  def critic(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    CtxMatchesPack.fired_counts << ctx.matches.size
    ctx.matches.each { |m| CtxMatchesPack.captured << m.bindings }
  end

  pack(name: "ctxmatches", version: "0.1.0")
end

module CtxMatchesWherePack
  include Chronicle::Packs::DSL

  class_property fired : Array(String) = [] of String

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("claim", %({"text":"A","confidence":0.9}))
  end

  @[Behavior(name: "auditor", pattern: "(c:claim) WHERE c.confidence > 0.7")]
  def auditor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    CtxMatchesWherePack.fired << event.type
  end

  pack(name: "ctxmatcheswhere", version: "0.1.0")
end

private def ctx_matches_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

describe Chronicle::Runtime do
  it "populates ctx.matches with the pattern bindings (CONTRACT v0.7 #12)" do
    CtxMatchesPack.captured = [] of Hash(String, String)
    CtxMatchesPack.fired_counts = [] of Int32
    rt = ctx_matches_runtime
    rt.load_pack(CtxMatchesPack::PACK)
    rt.run_goal("g")

    # Handler fires once, with one binding carrying c1 / c2 / r.
    CtxMatchesPack.fired_counts.should eq([1])
    CtxMatchesPack.captured.size.should eq(1)
    bindings = CtxMatchesPack.captured[0]
    bindings.has_key?("c1").should be_true
    bindings.has_key?("c2").should be_true
    bindings.has_key?("r").should be_true
  end

  it "is empty for a pattern behavior on a non-matching event (no bindings)" do
    CtxMatchesPack.captured = [] of Hash(String, String)
    rt = ctx_matches_runtime
    rt.load_pack(CtxMatchesPack::PACK)
    rt.run_goal("g")

    # goal.created did not match the pattern; only the relation.created fired.
    CtxMatchesPack.captured.size.should eq(1)
  end

  it "fires pattern-only behaviors on every matching non-lifecycle event" do
    CtxMatchesWherePack.fired = [] of String
    rt = ctx_matches_runtime
    rt.load_pack(CtxMatchesWherePack::PACK)
    rt.run_goal("g")

    CtxMatchesWherePack.fired.should eq(["object.created"])
  end
end
