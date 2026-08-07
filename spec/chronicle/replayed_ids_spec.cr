require "../spec_helper"

# `GraphProjection#replayed_ids` — every event id rebuilt by `GraphProjection.replay`
# (the `Runtime.load` / `Runtime.fork` seam), distinct from live-emitted events.
# Ported from activegraph.core.graph.Graph.replayed_ids / _replay_event
# (CONTRACT v0.5 #14: replay rebuilds graph state; it does not fire behaviors).

module ReplayedIdsHelper
  extend self

  def event(seq : UInt64, id : String, type : String = "object.created", payload : String = %({"id":"x","type":"doc","data":{}})) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: id,
      type: type, actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload,
    )
  end
end

describe Chronicle::GraphProjection do
  it "replay marks every event id as replayed" do
    events = [
      ReplayedIdsHelper.event(1_u64, "evt_1"),
      ReplayedIdsHelper.event(2_u64, "evt_2"),
      ReplayedIdsHelper.event(3_u64, "evt_3"),
    ]
    graph = Chronicle::GraphProjection.replay(events)

    graph.replayed_ids.should eq(Set{"evt_1", "evt_2", "evt_3"})
  end

  it "live-emitted events are not replayed" do
    graph = Chronicle::GraphProjection.empty
    graph.emit(ReplayedIdsHelper.event(1_u64, "evt_1"))
    graph.emit(ReplayedIdsHelper.event(2_u64, "evt_2"))

    graph.replayed_ids.should be_empty
  end

  it "an empty graph has no replayed ids" do
    Chronicle::GraphProjection.empty.replayed_ids.should be_empty
  end

  it "Runtime.load exposes the replayed ids on the loaded graph" do
    db = File.join(Dir.tempdir, "chronicle_replayed_#{Random::Secure.hex(4)}.db")
    store = Chronicle::SQLiteEventStore.new(db, run_id: "replay_parent")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
    graph.add_object("doc", %({"text":"hello"}))
    n = store.count

    loaded = Chronicle::Runtime(PackModel).load(db, rt.run_id, agent)
    loaded.graph.not_nil!.replayed_ids.size.should eq(n.to_i)
    loaded.graph.not_nil!.events.all? { |event| loaded.graph.not_nil!.replayed_ids.includes?(event.id) }.should be_true
  ensure
    File.delete(db) if db && File.exists?(db)
  end
end
