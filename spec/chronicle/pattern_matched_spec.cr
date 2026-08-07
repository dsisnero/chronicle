require "../spec_helper"

# `pattern.matched` lifecycle marker — emitted when a pattern-based behavior
# fires, so the trace shows the bindings. Ported from
# activegraph.runtime.runtime.Runtime#_emit_pattern_matched: payload carries
# behavior name, triggering event_id, matches_count, and the pattern string.

module PatternMatchedPack
  include Chronicle::Packs::DSL

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
    # no-op handler
  end

  pack(name: "patternmatched", version: "0.1.0")
end

private def pattern_matched_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

describe Chronicle::Runtime do
  it "emits a pattern.matched marker when a pattern-based behavior fires" do
    rt = pattern_matched_runtime
    rt.load_pack(PatternMatchedPack::PACK)
    rt.run_goal("g")

    markers = rt.store.iter_events.select { |e| e.type == "pattern.matched" }
    markers.size.should eq(1)
    payload = JSON.parse(markers[0].payload).as_h
    payload["behavior"].as_s.should eq("patternmatched.critic")
    payload["matches_count"].as_i.should eq(1)
    payload["pattern"].as_s.should eq("(c1:claim)-[r:contradicts]->(c2:claim)")
    payload["event_id"].as_s.should_not be_empty
  end
end
