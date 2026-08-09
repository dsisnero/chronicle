require "../spec_helper"

# Runtime-level sink surface (CONTRACT v1.8): delegates to the attached
# graph. Historical events reconstructed by load/fork are never offered.

private def runtime_sinks_harness : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel), Chronicle::TestingSink}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  sink = Chronicle::TestingSink.new
  {store, graph, rt, sink}
end

describe Chronicle::Runtime do
  it "add_sink attaches a named sink and sink_statuses reports it" do
    store, graph, rt, sink = runtime_sinks_harness
    name = rt.add_sink(sink, name: "observer")
    name.should eq("observer")

    statuses = rt.sink_statuses
    statuses.has_key?("observer").should be_true
  end

  it "delivers live events to the sink (lifecycle included)" do
    store, graph, rt, sink = runtime_sinks_harness
    rt.add_sink(sink, name: "observer")
    graph.add_object("memo", %({"text":"accepted"}))
    rt.flush_sinks

    sink.events.map(&.type).should contain("object.created")
  end

  it "remove_sink detaches and closes one sink" do
    store, graph, rt, sink = runtime_sinks_harness
    name = rt.add_sink(sink, name: "observer")
    removed = rt.remove_sink(name)
    removed.should be_true
    rt.sink_statuses.has_key?(name).should be_false
  end

  it "close_sinks detaches and closes all sinks" do
    store, graph, rt, sink = runtime_sinks_harness
    rt.add_sink(sink, name: "one")
    rt.close_sinks
    rt.sink_statuses.should be_empty
  end
end
