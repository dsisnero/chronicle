require "./support/example_support"

# Port of vendor/activegraph/examples/diligence_with_tools.py (the v0.7
# contract): tool use, a Cypher pattern subscription, `activate_after`, and a
# fork that replays both the LLM cache and the tool cache.
#
#   1. planner bootstraps the run from the goal (a goal_record object).
#   2. researcher is an `@[LLMBehavior]` that uses web_fetch + graph_query in a
#      runtime-owned LLM ↔ tool turn loop; the handler sees only the final
#      parsed `Findings`.
#   3. critic subscribes to the Cypher pattern
#      `(c1:claim)-[r:contradicts]->(c2:claim) WHERE c1.confidence > 0.7 ...`.
#   4. nag declares `activate_after: 2` (event-count scheduling).
#   5. The run is saved to SQLite and forked with `replay_llm_cache` AND
#      `replay_tool_cache`; the fork rebuilds the same prompts/tool calls and
#      serves them from the recorded events — zero new model calls and zero new
#      tool invocations.

module DiligenceToolsExample
  include Chronicle::Packs::DSL

  class_property critiques : Int32 = 0
  class_property nags : Int32 = 0
  class_property web_fetches : Int32 = 0
  class_property graph_queries : Int32 = 0

  struct ClaimOut
    include JSON::Serializable
    property text : String
    property confidence : Float64
  end

  struct Findings
    include JSON::Serializable
    property claims : Array(ClaimOut)
    property? contradiction : Bool = false
  end

  @[Behavior(name: "planner", on: ["goal.created"])]
  def planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    goal = JSON.parse(event.payload)["goal"].as_s
    graph.add_object("goal_record", %({"goal":#{goal.to_json}}))
  end

  @[LLMBehavior(name: "researcher", on: ["object.created"], where: {"type" => "goal_record"},
    tools: ["web_fetch", "graph_query"], output_schema: Findings,
    deterministic: true, view: {around: "id", depth: 1}, max_tool_turns: 3,
    description: "Research the goal using the web_fetch and graph_query tools.")]
  def researcher(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : Findings)
    claims = output.claims.map do |claim|
      graph.add_object("claim", %({"text":#{claim.text.to_json},"confidence":#{claim.confidence}}))
    end
    if output.contradiction? && claims.size >= 2
      graph.add_relation(claims[0].id, claims[1].id, "contradicts")
    end
  end

  @[Behavior(name: "critic", on: ["relation.created"], where: {"type" => "contradicts"},
    pattern: "(c1:claim)-[r:contradicts]->(c2:claim) WHERE c1.confidence > 0.7 AND c2.confidence > 0.7")]
  def critic(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    DiligenceToolsExample.critiques += 1
  end

  @[Behavior(name: "nag", on: ["object.created"], where: {"type" => "goal_record"}, activate_after: 2)]
  def nag(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    id = JSON.parse(event.payload)["id"].as_s
    DiligenceToolsExample.nags += 1 if graph.get_object(id)
  end

  @[Tool(name: "web_fetch", description: "Fetch a document by URL.")]
  def web_fetch(args : String) : String
    DiligenceToolsExample.web_fetches += 1
    %({"url":#{JSON.parse(args)["url"].as_s.to_json},"text":"fixture document"})
  end

  @[Tool(name: "graph_query", description: "Query the graph for object references.")]
  def graph_query(args : String) : String
    DiligenceToolsExample.graph_queries += 1
    %({"refs":[]})
  end

  pack(name: "diligencetools", version: "0.1.0")
end

def diligence_with_tools_main
  # Two tool turns, then the final structured findings with a contradiction.
  model = ExampleSupport::ScriptedTurnModel.new([
    ExampleSupport.turn_tool("c1", "diligencetools.web_fetch", %({"url":"https://northwind.example/10k"})),
    ExampleSupport.turn_tool("c2", "diligencetools.graph_query", %({"object_type":"claim"})),
    ExampleSupport.turn_text(%({"claims":[{"text":"Revenue grew 18%","confidence":0.9},{"text":"Revenue fell 7%","confidence":0.8}],"contradiction":true})),
  ])

  db = File.join(Dir.tempdir, "chronicle_diligence_with_tools.db")
  File.delete(db) if File.exists?(db)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
  _evt_store, graph, runtime = ExampleSupport.build(model, store: store, run_id: "parent")
  runtime.load_pack(DiligenceToolsExample::PACK)

  runtime.run_goal("Research Northwind Robotics")
  runtime.save_state
  parent_events = runtime.store.iter_events
  puts "[step 1] run #{runtime.run_id}: #{graph.all_objects.size} objects, #{graph.all_relations.size} relations"
  puts "  tool calls:   web_fetch=#{DiligenceToolsExample.web_fetches} graph_query=#{DiligenceToolsExample.graph_queries}"
  puts "  pattern hits: critic=#{DiligenceToolsExample.critiques}"
  puts "  activate_after hits: nag=#{DiligenceToolsExample.nags}"
  puts "  tool events:  #{parent_events.count { |e| e.type == "tool.requested" }} requested / #{parent_events.count { |e| e.type == "tool.responded" }} responded"
  puts "  pattern.matched: #{parent_events.count { |e| e.type == "pattern.matched" }}  behavior.scheduled: #{parent_events.count { |e| e.type == "behavior.scheduled" }}"

  # ---- fork with both replay caches ---------------------------------------
  tools_before = DiligenceToolsExample.web_fetches + DiligenceToolsExample.graph_queries
  goal_event = parent_events.find { |event| event.type == "goal.created" }.not_nil!
  fork = runtime.fork(
    at_event: goal_event.id,
    label: "cached-replay",
    replay_llm_cache: true,
    replay_tool_cache: true,
  )
  fork.run_until_idle
  fork.save_state
  tools_after = DiligenceToolsExample.web_fetches + DiligenceToolsExample.graph_queries
  llm_hits = fork.store.iter_events.count do |event|
    event.type == "llm.responded" && JSON.parse(event.payload).as_h["cache_hit"]?.try(&.as_bool?) == true
  end
  puts "\n[step 2] fork at #{goal_event.id} -> #{fork.run_id}"
  puts "  parent cache entries:             #{Chronicle::LLMCache.from_events(parent_events).size}"
  puts "  LLM responses served from cache:  #{llm_hits}"
  puts "  new tool invocations in fork:     #{tools_after - tools_before}"
  puts "\n=== fork trace ==="
  ExampleSupport.print_trace(fork)

  File.delete(db) if File.exists?(db)
end

diligence_with_tools_main
