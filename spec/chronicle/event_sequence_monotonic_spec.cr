require "../spec_helper"

# One run has ONE monotonic event ordering, regardless of which emitter
# produced an event (runtime lifecycle vs graph mutation). Ported from the
# activegraph invariant that the event store is the sequencing authority: there
# is no separate per-emitter counter, so the merged log is strictly increasing
# and directly encodable.
#
# Regression guard: graph mutations previously numbered from
# `GraphProjection#next_sequence` (applied-events count) while runtime events
# used `Runtime#next_seq` (store count), so a memory-backed run produced
# `1, 2, 3, 1, 2, 6` and `EventLog.from_events` raised `EventSequenceError`.

module EventSequenceMonotonicPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "seed", on: ["goal.created"])]
  def seed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    graph.add_object("task", %({"title":"t"}))
    graph.add_object("task", %({"title":"u"}))
    graph.emit("task.done", %({"task":"t"}))
  end

  pack(name: "eventsequencemonotonic", version: "0.1.0")
end

private def memory_sequenced_runtime : {Chronicle::MemoryEventStore, Chronicle::Runtime(PackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  {store, rt}
end

describe "event sequencing" do
  it "keeps runtime-emitted and graph-mutation events on one monotonic stream" do
    store, rt = memory_sequenced_runtime
    rt.load_pack(EventSequenceMonotonicPack::PACK)
    rt.run_goal("g")

    sequences = store.iter_events.map(&.sequence)
    sequences.size.should be > 3
    # Strictly increasing (no duplicate/graph-reset sequences).
    (1...sequences.size).each { |i| sequences[i].should be > sequences[i - 1] }
  end

  it "produces a memory-backed log that EventLogCodec encodes directly" do
    store, rt = memory_sequenced_runtime
    rt.load_pack(EventSequenceMonotonicPack::PACK)
    rt.run_goal("g")

    log = Chronicle::EventLog.from_events(store.iter_events)
    decoded = Chronicle::EventLogCodec.decode(Chronicle::EventLogCodec.encode(log))
    decoded.events.size.should eq(store.count)
  end

  it "supports graph.emit(event_type, payload) with the projection's counter" do
    store, rt = memory_sequenced_runtime
    rt.load_pack(EventSequenceMonotonicPack::PACK)
    rt.run_goal("g")

    custom = store.iter_events.find { |event| event.type == "task.done" }
    custom.should_not be_nil
    custom.not_nil!.id.should_not be_empty
  end
end
