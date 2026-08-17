require "../spec_helper"

# `Runtime#print_graph` — the upstream console renderer for the attached graph
# (runtime.py:3137). Chronicle's core is Sans-IO, so the method renders the
# upstream text format and returns it as a String; the CLI / caller prints it.
#
# Format (upstream):
#   graph:
#     objects (N):
#       <id>" <label>" (<status>)
#     relations (N):
#       <source> --<type>--> <target>
# where <label> is the object data's `title` or `text` field and <status> is
# its `status` field.

private def print_graph_runtime
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(
    Crig::Agent(PackModel).new(model: PackModel.new, preamble: ""),
    store: store,
    max_turns: 1,
  )
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
  {graph, rt}
end

describe Chronicle::Runtime do
  it "renders the attached graph in the upstream print_graph format" do
    graph, rt = print_graph_runtime
    research = graph.add_object("task", %({"title":"Research","status":"open"}))
    memo = graph.add_object("task", %({"text":"Draft memo"}))
    graph.add_relation(research.id, memo.id, "depends_on")

    expected = String.build do |io|
      io << "graph:\n"
      io << "  objects (2):\n"
      io << "    #{research.id} \"Research\" (open)\n"
      io << "    #{memo.id} \"Draft memo\"\n"
      io << "  relations (1):\n"
      io << "    #{research.id} --depends_on--> #{memo.id}\n"
    end

    rt.print_graph.should eq(expected)
  end

  it "renders an empty graph with zero counts" do
    _graph, rt = print_graph_runtime
    rt.print_graph.should eq("graph:\n  objects (0):\n  relations (0):\n")
  end
end
