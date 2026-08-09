require "../spec_helper"

# Cooperative bounded drain (CONTRACT v1.10 #3): single-writer hosts can
# interleave reads/commands between quanta. run_quantum returns process
# observations (never written to the log) and does NOT claim false idle.

module RunQuantumSpecPacks
  module ChainPack
    include Chronicle::Packs::DSL

    # On every unit object.created, add the next unit until ordinal 5.
    @[Behavior(name: "chain", on: ["object.created"], where: {"type" => "unit"})]
    def chain(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      payload = JSON.parse(event.payload).as_h
      data = payload["data"]?.try(&.as_h?) || {} of String => JSON::Any
      ordinal = data["ordinal"]?.try(&.as_i) || 0
      if ordinal < 5
        graph.add_object("unit", %({"ordinal":#{ordinal + 1}}))
      end
    end

    pack(name: "quantum", version: "0.1.0")
  end
end

private def quantum_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

  # Register the chain behavior directly (upstream registers via global
  # @behavior decorators — no pack.loaded event enters the log). A pack
  # load would emit pack.loaded into the store, which is queue-visible
  # (CONTRACT v0.9 #13) and would occupy one extra quantum slot.
  pack = RunQuantumSpecPacks::ChainPack::PACK
  rt.pack_behaviors.concat(pack.behaviors.map { |b| b.canonicalize(pack, {} of String => JSON::Any) })

  graph.add_object("unit", %({"ordinal":0}))
  {store, graph, rt}
end

describe Chronicle::RunQuantumResult do
  it "exposes the process observations" do
    result = Chronicle::RunQuantumResult.new(
      queue_events_processed: 3,
      elapsed_seconds: 0.1,
      queue_depth: 1,
      max_queue_depth: 2,
      delayed_depth: 0,
      idle: false,
      budget_exhausted: false,
    )
    result.queue_events_processed.should eq(3)
    result.elapsed_seconds.should eq(0.1)
    result.queue_depth.should eq(1)
    result.max_queue_depth.should eq(2)
    result.delayed_depth.should eq(0)
    result.idle.should be_false
    result.budget_exhausted.should be_false
  end
end

describe Chronicle::Runtime do
  it "yields without a false idle and finishes once (test_quantum_yields_without_a_false_idle)" do
    store, graph, rt = quantum_runtime

    first = rt.run_quantum(max_queue_events: 1, max_seconds: 1.0)
    first.queue_events_processed.should eq(1)
    first.queue_depth.should eq(1)
    first.idle.should be_false
    first.budget_exhausted.should be_false
    store.iter_events.any? { |e| e.type == "runtime.idle" }.should be_false

    quanta = 1
    result = first
    while !result.idle
      result = rt.run_quantum(max_queue_events: 1, max_seconds: 1.0)
      quanta += 1
    end

    quanta.should eq(6)
    result.queue_depth.should eq(0)
    store.iter_events.count { |e| e.type == "runtime.idle" }.should eq(1)
    # The chain ran to completion: all six units projected.
    graph.objects(type: "unit").size.should eq(6)
  end

  it "cooperative and full drains produce byte-identical logs (test_cooperative_and_full_drains)" do
    store_c, graph_c, rt_c = quantum_runtime
    while !rt_c.run_quantum(max_queue_events: 2, max_seconds: 1.0).idle
    end
    cooperative_events = store_c.iter_events.map(&.canonical_json)

    store_f, graph_f, rt_f = quantum_runtime
    rt_f.run_until_idle
    full_events = store_f.iter_events.map(&.canonical_json)

    cooperative_events.should eq(full_events)
  end

  it "partial quanta remain restart recoverable" do
    store, graph, rt = quantum_runtime
    result = rt.run_quantum(max_queue_events: 1, max_seconds: 1.0)
    result.idle.should be_false

    # A fresh runtime over the same store resumes from where the first one
    # stopped: events whose behaviors already fired are skipped (the
    # fired_on set from behavior.started), so the chain completes exactly
    # once — no re-firing (upstream Runtime.load + _requeue_unfired).
    agent2 = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la2 = Chronicle::LogAgent(PackModel).new(agent2, store: store, max_turns: 1)
    rt2 = Chronicle::Runtime(PackModel).new(store: store, log_agent: la2, graph: graph, run_id: "default")
    pack = RunQuantumSpecPacks::ChainPack::PACK
    rt2.pack_behaviors.concat(pack.behaviors.map { |b| b.canonicalize(pack, {} of String => JSON::Any) })
    rt2.resume_from_store(store.iter_events)
    while !rt2.run_quantum(max_queue_events: 1, max_seconds: 1.0).idle
    end

    ordinals = graph.objects(type: "unit").map { |obj| JSON.parse(obj.data)["ordinal"].as_i }.sort
    ordinals.should eq([0, 1, 2, 3, 4, 5])
  end

  it "rejects invalid bounds loudly" do
    store, graph, rt = quantum_runtime
    expect_raises(ArgumentError) { rt.run_quantum(max_queue_events: 0, max_seconds: 1.0) }
    expect_raises(ArgumentError) { rt.run_quantum(max_queue_events: -1, max_seconds: 1.0) }
    expect_raises(ArgumentError) { rt.run_quantum(max_queue_events: 1, max_seconds: 0.0) }
    expect_raises(ArgumentError) { rt.run_quantum(max_queue_events: 1, max_seconds: -1.0) }
  end
end
