require "./support/example_support"

# Port of vendor/activegraph/examples/quickstart.py — "the killer demo" that
# defines the v0 public API: build a graph, register three reactive behaviors
# (planner / researcher / unblock), run a goal, print the trace and the graph.
#
# Port divergences (see plans/parity.md "Intentional Divergence"):
#   * upstream global `@behavior`/`@relation_behavior` decorators become a
#     Crystal pack (`@[Behavior]`/`@[RelationBehavior]`) loaded with `load_pack`;
#   * upstream object.created payloads nest the object under `"object"`; the
#     port flattens the payload to `id`/`type`/`data`.

module QuickstartExample
  include Chronicle::Packs::DSL

  @[Behavior(name: "planner", on: ["goal.created"])]
  def planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    goal = JSON.parse(event.payload)["goal"].as_s
    research = graph.add_object("task", %({"title":#{("Research: " + goal).to_json},"status":"open"}))
    memo = graph.add_object("task", %({"title":"Draft memo","status":"blocked"}))
    graph.add_relation(research.id, memo.id, "depends_on")
  end

  @[Behavior(name: "researcher", on: ["object.created"], where: {"type" => "task"})]
  def researcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    payload = JSON.parse(event.payload).as_h
    data = payload["data"].as_h
    return unless data["status"].as_s == "open" && data["title"].as_s.includes?("Research")

    graph.add_object("claim", %({"text":"Market appears early but growing.","confidence":0.7,"evidence":[]}))
    ExampleSupport.emit(graph, "task.completed", %({"task_id":#{payload["id"].as_s.to_json}}))
  end

  @[RelationBehavior(name: "unblock", relation_type: "depends_on", on: ["task.completed"])]
  def unblock(relation : Chronicle::GraphRelation, event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    return unless JSON.parse(event.payload)["task_id"].as_s == relation.from_id
    graph.patch_object(relation.to_id, %({"status":"open"}))
  end

  pack(name: "quickstart", version: "0.1.0")
end

_store, _graph, runtime = ExampleSupport.build(ExampleSupport::ScriptedModel.new([] of String))
runtime.load_pack(QuickstartExample::PACK)

puts "chronicle quickstart — the v0 runtime API demo"
puts
runtime.run_goal("Evaluate this startup idea")
ExampleSupport.print_trace(runtime)
puts
puts runtime.print_graph
