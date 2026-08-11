require "../spec_helper"

describe Chronicle::SinkConfig do
  it "defaults to a capacity of 1024 and DROP_NEWEST" do
    config = Chronicle::SinkConfig.new(Chronicle::TestingSink.new)
    config.name.should be_nil
    config.queue_capacity.should eq(1024)
    config.overflow_policy.should eq(Chronicle::OverflowPolicy::DropNewest)
  end

  it "rejects an empty name" do
    error = expect_raises(ArgumentError) do
      Chronicle::SinkConfig.new(Chronicle::TestingSink.new, name: "  ")
    end
    error.message.not_nil!.should contain("name must not be empty")
  end

  it "requires a positive integer capacity" do
    expect_raises(ArgumentError) do
      Chronicle::SinkConfig.new(Chronicle::TestingSink.new, queue_capacity: 0)
    end
    expect_raises(ArgumentError) do
      Chronicle::SinkConfig.new(Chronicle::TestingSink.new, queue_capacity: -1)
    end
  end
end

describe Chronicle::Runtime do
  it "attaches sinks passed at construction with default names" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(
      store: store, log_agent: la, graph: graph,
      sinks: [Chronicle::SinkConfig.new(Chronicle::TestingSink.new)],
    )

    rt.sink_statuses.size.should eq(1)
    rt.sink_statuses.keys.first.should eq("TestingSink")
  end

  it "uses the configured name for a named sink" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(
      store: store, log_agent: la, graph: graph,
      sinks: [Chronicle::SinkConfig.new(Chronicle::TestingSink.new, name: "observer")],
    )

    rt.sink_statuses.has_key?("observer").should be_true
  end

  it "rejects a duplicate sink name before attaching anything" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)

    error = expect_raises(ArgumentError) do
      Chronicle::Runtime(PackModel).new(
        store: store, log_agent: la, graph: graph,
        sinks: [
          Chronicle::SinkConfig.new(Chronicle::TestingSink.new, name: "dup"),
          Chronicle::SinkConfig.new(Chronicle::TestingSink.new, name: "dup"),
        ],
      )
    end
    error.message.not_nil!.should contain("appears more than once")
    graph.sink_statuses.should be_empty
  end

  it "delivers live events to a sink attached via constructor" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    sink = Chronicle::TestingSink.new
    rt = Chronicle::Runtime(PackModel).new(
      store: store, log_agent: la, graph: graph,
      sinks: [Chronicle::SinkConfig.new(sink, name: "observer")],
    )

    graph.add_object("memo", %({"text":"accepted"}))
    rt.flush_sinks
    sink.events.map(&.type).should contain("object.created")
  end
end
