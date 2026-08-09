require "../spec_helper"

# Context-read tracing runtime wiring (CONTRACT v1.10 #1): opt-in
# trace_context_reads flag threads a ReadRecorder through ctx.view and
# graph.get_object reads, then emits ONE batched context.read right after
# the behavior's terminal lifecycle event.

module ContextReadRuntimePacks
  module ReaderPack
    include Chronicle::Packs::DSL

    class_property read_surface = :view

    @[Behavior(name: "reader", on: ["goal.created"])]
    def reader(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      case ReaderPack.read_surface
      when :view
        ctx.view.objects(type: "doc")
      when :get_object
        graph.get_object("doc#1")
      when :mixed
        docs = ctx.view.objects(type: "doc")
        docs.each { |obj| graph.get_object(obj.id) }
      end
    end

    pack(name: "ctxreader", version: "0.1.0")
  end

  module WriterPack
    include Chronicle::Packs::DSL

    @[Behavior(name: "writer", on: ["goal.created"])]
    def writer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      graph.add_object("summary", %({"ok":true}))
    end

    pack(name: "ctxwriter", version: "0.1.0")
  end
end

private def context_read_runtime(
  pack : Chronicle::Pack,
  trace : Bool,
  read_surface : Symbol = :view,
) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
  ContextReadRuntimePacks::ReaderPack.read_surface = read_surface
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, trace_context_reads: trace)
  rt.load_pack(pack)
  {store, graph, rt}
end

private def context_read_events(store : Chronicle::MemoryEventStore) : Array(Chronicle::Event)
  store.iter_events.select { |e| e.type == "context.read" }
end

describe Chronicle::Runtime do
  it "emits ONE context.read per execution, deduplicated first-read order (test_one_event_per_execution)" do
    store, graph, rt = context_read_runtime(ContextReadRuntimePacks::ReaderPack::PACK, trace: true, read_surface: :mixed)
    graph.add_object("doc", %({"n":1}))
    graph.add_object("doc", %({"n":2}))
    rt.run_goal("go")

    reads = context_read_events(store)
    reads.size.should eq(1)
    payload = JSON.parse(reads.first.payload).as_h
    payload["behavior"].as_s.should eq("ctxreader.reader")
    payload["object_ids"].as_a.map(&.as_s).should eq(["doc#1", "doc#2"])
    payload["count"].as_i.should eq(2)
    payload.has_key?("truncated").should be_false
  end

  it "emits the read right after the behavior's lifecycle event, with execution_event_id = the started event (test_emitted_at_frame_commit)" do
    store, graph, rt = context_read_runtime(ContextReadRuntimePacks::ReaderPack::PACK, trace: true, read_surface: :view)
    graph.add_object("doc", %({"n":1}))
    rt.run_goal("go")

    types = store.iter_events.map(&.type)
    read_index = types.index("context.read").not_nil!
    # Chronicle plain behaviors emit behavior.started (no behavior.completed);
    # the read commits right after the last behavior.* lifecycle event.
    types[read_index - 1].should start_with("behavior.")

    read = context_read_events(store).first
    started = store.iter_events.find { |e| e.type == "behavior.started" }.not_nil!
    JSON.parse(read.payload)["execution_event_id"].as_s.should eq(started.id)
  end

  it "is opt-in: default off emits no context.read (test_default_off_emits_no_context_read_events)" do
    store, graph, rt = context_read_runtime(ContextReadRuntimePacks::ReaderPack::PACK, trace: false, read_surface: :view)
    graph.add_object("doc", %({"n":1}))
    rt.run_goal("go")

    context_read_events(store).should be_empty
  end

  it "traces graph.get_object point reads but not relations or misses" do
    store, graph, rt = context_read_runtime(ContextReadRuntimePacks::ReaderPack::PACK, trace: true, read_surface: :get_object)
    a = graph.add_object("doc", %({"n":1}))
    b = graph.add_object("doc", %({"n":2}))
    graph.add_relation(a.id, b.id, "links")
    rt.run_goal("go")

    reads = context_read_events(store)
    reads.size.should eq(1)
    payload = JSON.parse(reads.first.payload).as_h
    payload["object_ids"].as_a.map(&.as_s).should eq(["doc#1"])
    payload["count"].as_i.should eq(1)
  end

  it "read-free frames emit no trace even when enabled (test_read_free_frame_emits_no_trace)" do
    store, graph, rt = context_read_runtime(ContextReadRuntimePacks::WriterPack::PACK, trace: true)
    rt.run_goal("go")

    context_read_events(store).should be_empty
  end

  it "traces the ctx.view.objects read set (test_view_surface)" do
    store, graph, rt = context_read_runtime(ContextReadRuntimePacks::ReaderPack::PACK, trace: true, read_surface: :view)
    graph.add_object("doc", %({"n":1}))
    graph.add_object("doc", %({"n":2}))
    rt.run_goal("go")

    reads = context_read_events(store)
    payload = JSON.parse(reads.first.payload).as_h
    payload["object_ids"].as_a.map(&.as_s).should eq(["doc#1", "doc#2"])
  end
end
