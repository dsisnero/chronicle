require "../spec_helper"

# TraceFacade#lines (CONTRACT #18) — walks the event log in order and renders
# CONTRACT #18 lines, with replay-boundary rendering (CONTRACT v0.5 #22).
# Ported from activegraph.trace.printer.Trace.lines.

def store_with(*events : Chronicle::Event) : Chronicle::MemoryEventStore
  store = Chronicle::MemoryEventStore.new
  events.each { |e| store.append(e) }
  store
end

def trace_event(type : String, payload : String, id : String = "evt_1") : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: id,
    type: type, actor: "runtime", caused_by: nil, timestamp: Time.utc,
    payload: payload,
  )
end

describe Chronicle::TraceFacade do
  it "renders plain events in log order with format_event" do
    goal = trace_event("goal.created", %({"goal": "g"}))
    store = store_with(goal)
    Chronicle::TraceFacade.new(store).lines.should eq(["[goal.created]            user: \"g\""])
  end

  it "renders replayed events with the [replay.event] prefix and trailing boundary" do
    replayed = trace_event("goal.created", %({"goal": "old"}), id: "r1")
    store = store_with(replayed)
    lines = Chronicle::TraceFacade.new(store).lines(replayed_ids: Set{"r1"})
    lines.should eq([
      "[replay.event]            r1 goal.created \"old\"",
      "[replay.complete]         1 events replayed, graph reconstructed",
      "[runtime.idle]            ready to resume",
    ])
  end

  it "emits the replay.complete and ready-to-resume boundary once after replayed events" do
    replay = trace_event("object.created", %({"id": "task#1", "type": "task", "data": {"title": "T"}, "version": 1}), id: "r1")
    fresh = trace_event("goal.created", %({"goal": "new"}), id: "g2")
    store = store_with(replay, fresh)
    lines = Chronicle::TraceFacade.new(store).lines(replayed_ids: Set{"r1"})
    lines.should eq([
      "[replay.event]            r1 object.created task#1 \"T\"",
      "[replay.complete]         1 events replayed, graph reconstructed",
      "[runtime.idle]            ready to resume",
      "[goal.created]            user: \"new\"",
    ])
  end

  it "renders replay object.created from the flat id payload" do
    replay = trace_event("object.created", %({"id": "task#9", "type": "task", "data": {"title": "R"}, "version": 1}), id: "r9")
    store = store_with(replay)
    Chronicle::TraceFacade.new(store).lines(replayed_ids: Set{"r9"}).should eq([
      "[replay.event]            r9 object.created task#9 \"R\"",
      "[replay.complete]         1 events replayed, graph reconstructed",
      "[runtime.idle]            ready to resume",
    ])
  end

  it "renders replay relation.created from the flat from_id/to_id/type payload" do
    replay = trace_event("relation.created", %({"id": "rel#1", "type": "depends_on", "from_id": "a", "to_id": "b"}), id: "r1")
    store = store_with(replay)
    Chronicle::TraceFacade.new(store).lines(replayed_ids: Set{"r1"}).should eq([
      "[replay.event]            r1 relation.created a --depends_on--> b",
      "[replay.complete]         1 events replayed, graph reconstructed",
      "[runtime.idle]            ready to resume",
    ])
  end

  it "appends the replay boundary even when all events are replayed" do
    replay = trace_event("object.created", %({"id": "task#1", "type": "task", "data": {"title": "T"}, "version": 1}), id: "r1")
    store = store_with(replay)
    lines = Chronicle::TraceFacade.new(store).lines(replayed_ids: Set{"r1"})
    lines.should eq([
      "[replay.event]            r1 object.created task#1 \"T\"",
      "[replay.complete]         1 events replayed, graph reconstructed",
      "[runtime.idle]            ready to resume",
    ])
  end
end
