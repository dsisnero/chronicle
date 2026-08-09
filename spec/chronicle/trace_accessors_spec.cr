require "../spec_helper"

# Trace structured accessors: events() and failures() (v1.3). The trace
# facade previously exposed only formatted output; these pin the structured
# surface so trace consumers can pick an event id for fork().

module TraceAccessorPacks
  module MakerPack
    include Chronicle::Packs::DSL

    @[Behavior(name: "maker", on: ["goal.created"])]
    def maker(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      graph.add_object("task", %({"title":"x"}))
    end

    pack(name: "tracemaker", version: "0.1.0")
  end

  module BrokenPack
    include Chronicle::Packs::DSL

    @[Behavior(name: "broken", on: ["goal.created"])]
    def broken(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      raise "kaboom"
    end

    pack(name: "tracebroken", version: "0.1.0")
  end
end

private def trace_harness(pack : Chronicle::Pack) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  rt.load_pack(pack)
  {store, graph, rt}
end

describe Chronicle::Runtime do
  it "trace.events returns the run's events with ids (test_trace_events_returns_event_objects_with_ids)" do
    store, graph, rt = trace_harness(TraceAccessorPacks::MakerPack::PACK)
    rt.run_goal("hi")

    events = rt.trace.events
    events.should_not be_empty
    events.size.should eq(store.iter_events.size)
    events.all? { |e| !e.id.empty? }.should be_true

    # It's a copy: mutating the returned list changes nothing.
    events.clear
    rt.trace.events.should_not be_empty
  end

  it "trace.events ids are usable as fork points" do
    path = File.join(pack_spec_dir("trace_accessor_fork"), "run.db")
    store = Chronicle::SQLiteEventStore.new(path, run_id: "trace_fork")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: "trace_fork")
    rt.load_pack(TraceAccessorPacks::MakerPack::PACK)
    rt.run_goal("hi")

    fork_point = rt.trace.events.first.id
    fork_point.should_not be_empty
    fork = rt.fork(at_event: fork_point)
    fork.run_id.should_not eq(rt.run_id)
    fork.trace.events.first.id.should eq(fork_point)
  end

  it "trace.failures surfaces the behavior.failed events with traceback (test_trace_failures_surfaces_traceback)" do
    store, graph, rt = trace_harness(TraceAccessorPacks::BrokenPack::PACK)
    rt.run_goal("hi")

    failures = rt.trace.failures
    failures.size.should eq(1)
    payload = JSON.parse(failures.first.payload).as_h
    payload["behavior"].as_s.should eq("tracebroken.broken")
    payload["exception_type"].as_s.should eq("Exception")
    payload["message"].as_s.should eq("kaboom")
    # The full traceback is recorded (v1.0.3) and discoverable — Crystal
    # backtraces name the failing method frame.
    payload["traceback"].as_s.should contain("broken")
  end

  it "trace.failures is empty on a clean run (test_trace_failures_empty_on_clean_run)" do
    store, graph, rt = trace_harness(TraceAccessorPacks::MakerPack::PACK)
    rt.run_goal("hi")

    rt.trace.failures.should be_empty
  end
end
