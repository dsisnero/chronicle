require "../spec_helper"

# `Chronicle::Registry` — match events to behaviors (CONTRACT #10: registration
# order for ties). Ported from activegraph.runtime.registry: `match(event,
# graph)` returns (behavior, matching_relations, pattern_matches) triples in
# registration order. A behavior with both `on=[...]` and `pattern=...`
# requires BOTH conditions; a behavior with only `pattern=` (empty `on`)
# matches every non-lifecycle event; relation behaviors fire on ANY event whose
# payload references a candidate relation's source or target.

module RegistryHelper
  extend self

  def obj_event(seq : UInt64, id : String, type : String, data : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","data":#{data}}),
    )
  end

  def rel_event(seq : UInt64, id : String, type : String, from : String, to : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "relation.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","from_id":"#{from}","to_id":"#{to}"}),
    )
  end

  def mixed_graph : Chronicle::GraphProjection
    seq = 1_u64
    events = [] of Chronicle::Event
    a = obj_event(seq, "obj_a", "claim", %({"text":"A","status":"open"})); seq += 1
    e = obj_event(seq, "obj_e", "source", %({"text":"E"})); seq += 1
    r1 = rel_event(seq, "rel_1", "supports", "obj_a", "obj_e"); seq += 1
    r2 = rel_event(seq, "rel_2", "supports", "obj_b", "obj_e"); seq += 1
    b = obj_event(seq, "obj_b", "claim", %({"text":"B"})); seq += 1
    [a, e, r1, r2, b].reduce(Chronicle::GraphProjection.empty) { |g, ev| g.apply(ev) }
  end

  def plain_event(seq : UInt64, type : String, payload : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: type, actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload,
    )
  end

  def where(pairs : Hash(String, String)) : Hash(String, JSON::Any)
    pairs.to_h { |k, v| {k, JSON::Any.new(v)} }
  end
end

describe Chronicle::Registry do
  it "all returns behaviors in registration order and index_of finds them" do
    a = Chronicle::Packs::PackBehavior.new(name: "a", event_types: ["goal.created"])
    b = Chronicle::Packs::PackBehavior.new(name: "b", event_types: ["object.created"])
    reg = Chronicle::Registry.new([a, b])
    reg.all.should eq([a, b])
    reg.index_of(a).should eq(0)
    reg.index_of(b).should eq(1)
    reg.index_of(Chronicle::Packs::PackBehavior.new(name: "nope")).should eq(-1)
  end

  it "match filters by event type (on non-empty)" do
    echo = Chronicle::Packs::PackBehavior.new(name: "echo", event_types: ["goal.created"])
    other = Chronicle::Packs::PackBehavior.new(name: "other", event_types: ["object.created"])
    reg = Chronicle::Registry.new([echo, other])

    event = RegistryHelper.plain_event(1_u64, "goal.created", %({"goal":"x"}))
    triples = reg.match(event, Chronicle::GraphProjection.empty)
    triples.map(&.behavior.name).should eq(["echo"])
  end

  it "suppresses lifecycle events for pattern-only behaviors (empty on)" do
    pat = Chronicle::Packs::PackBehavior.new(name: "pat", pattern: "(c:claim)")
    reg = Chronicle::Registry.new([pat])

    lifecycle = RegistryHelper.plain_event(1_u64, "behavior.started", %({}))
    reg.match(lifecycle, Chronicle::GraphProjection.empty).should be_empty

    non_lifecycle = RegistryHelper.plain_event(2_u64, "claim.touched", %({"id":"x"}))
    reg.match(non_lifecycle, Chronicle::GraphProjection.empty).should be_empty # no claim in graph
  end

  it "pattern behavior returns pattern matches (bindings) against post-event graph" do
    g = RegistryHelper.mixed_graph
    pat = Chronicle::Packs::PackBehavior.new(name: "pat", pattern: "(c:claim)")
    reg = Chronicle::Registry.new([pat])

    event = RegistryHelper.plain_event(10_u64, "claim.touched", %({"id":"obj_a"}))
    triples = reg.match(event, g)
    triples.size.should eq(1)
    triples[0].behavior.should eq(pat)
    triples[0].pattern_matches.should_not be_empty
  end

  it "relation behavior matches any event referencing a candidate relation endpoint" do
    g = RegistryHelper.mixed_graph
    rb = Chronicle::Packs::PackBehavior.new(
      name: "unblock", relation_type: "supports", event_types: ["claim.touched"],
      kind: Chronicle::Packs::PackBehaviorKind::Relation,
    )
    reg = Chronicle::Registry.new([rb])

    # Event references obj_a -> only the supports edge into obj_a.
    event = RegistryHelper.plain_event(10_u64, "claim.touched", %({"object":{"id":"obj_a"}}))
    matched = reg.match(event, g)
    matched.map { |t| t.relations.map(&.id) }.flatten.sort.should eq(["rel_1"])

    # Event referencing the shared source obj_e -> both supports edges.
    event2 = RegistryHelper.plain_event(11_u64, "claim.touched", %({"object":{"id":"obj_e"}}))
    matched2 = reg.match(event2, g)
    matched2.map { |t| t.relations.map(&.id) }.flatten.sort.should eq(["rel_1", "rel_2"])
  end

  it "relation behavior applies where= to the event payload" do
    g = RegistryHelper.mixed_graph
    rb = Chronicle::Packs::PackBehavior.new(
      name: "unblock", relation_type: "supports", event_types: ["claim.touched"],
      where: RegistryHelper.where({"status" => "open"}),
      kind: Chronicle::Packs::PackBehaviorKind::Relation,
    )
    reg = Chronicle::Registry.new([rb])

    event = RegistryHelper.plain_event(10_u64, "claim.touched", %({"object":{"id":"obj_a"},"status":"open"}))
    reg.match(event, g).size.should eq(1)

    event2 = RegistryHelper.plain_event(11_u64, "claim.touched", %({"object":{"id":"obj_a"},"status":"closed"}))
    reg.match(event2, g).should be_empty
  end

  it "where= on a plain behavior must pass" do
    watch = Chronicle::Packs::PackBehavior.new(
      name: "watch", event_types: ["claim.touched"], where: RegistryHelper.where({"kind" => "note"}),
    )
    reg = Chronicle::Registry.new([watch])

    event = RegistryHelper.plain_event(1_u64, "claim.touched", %({"kind":"note","id":"x"}))
    reg.match(event, Chronicle::GraphProjection.empty).size.should eq(1)

    event2 = RegistryHelper.plain_event(2_u64, "claim.touched", %({"kind":"other","id":"x"}))
    reg.match(event2, Chronicle::GraphProjection.empty).should be_empty
  end

  it "runtime dispatch fires a relation behavior on any event referencing a relation endpoint" do
    fired = [] of String
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    rb = Chronicle::Packs::PackBehavior.new(
      name: "unblock", relation_type: "supports", event_types: ["claim.touched"],
      kind: Chronicle::Packs::PackBehaviorKind::Relation,
      relation_handler: ->(relation : Chronicle::GraphRelation, event : Chronicle::Event, g : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext) {
        fired << relation.id
      },
    )
    rt.load_pack(Chronicle::Packs::Pack.new(
      name: "rel", version: "1.0.0", behaviors: [rb],
    ))

    # Build the graph: two supports edges into a shared source.
    a = graph.add_object("claim", %({"text":"A","status":"open"}))
    e = graph.add_object("source", %({"text":"E"}))
    graph.add_object("claim", %({"text":"B"}))
    r1 = graph.add_relation(a.id, e.id, "supports")
    r2 = graph.add_relation(graph.objects(type: "claim")[1].id, e.id, "supports")

    # A claim.touched event referencing the shared source reaches BOTH edges.
    store.append(RegistryHelper.plain_event(10_u64, "claim.touched", %({"object":{"id":"#{e.id}"}})))
    rt.run_until_idle
    fired.sort.should eq([r1.id, r2.id].sort)
  end
end
