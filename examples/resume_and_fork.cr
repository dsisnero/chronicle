require "./support/example_support"

# Port of vendor/activegraph/examples/resume_and_fork.py (the v0.5 contract):
# stop, save, reload in a fresh Runtime, resume, fork, inject a counter-
# hypothesis, and diff parent vs fork. Behaviors mirror the vendor script
# (planner / researcher / unblock), registered through the Crystal pack DSL.
#
# The Crystal port persists to SQLite and uses `Runtime.load` / `Runtime#fork`
# exactly like upstream; `graph.events` supplies the fork point by event id.

module ResumeForkExample
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

  pack(name: "resumefork", version: "0.1.0")
end

def resume_and_fork_main
  db = File.join(Dir.tempdir, "chronicle_resume_and_fork.db")
  File.delete(db) if File.exists?(db)

  # ---- step 1: run with a tight budget so we stop mid-flow, then save ------
  model = ExampleSupport::ScriptedModel.new([] of String)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
  _evt_store, graph, runtime = ExampleSupport.build(
    model,
    store: store,
    run_id: "parent",
    budget: Chronicle::Budget.new(limits: {"max_behavior_calls" => 1.0}),
  )
  runtime.load_pack(ResumeForkExample::PACK)
  runtime.run_goal("Evaluate this startup idea")
  runtime.save_state
  puts "[step 1] paused run #{runtime.run_id} after #{graph.events.size} events"

  # ---- step 2: fresh process: reload, re-register behaviors, resume -------
  agent = Crig::Agent(ExampleSupport::ScriptedModel).new(model: model, preamble: "")
  resumed = Chronicle::Runtime(ExampleSupport::ScriptedModel).load(db, runtime.run_id, agent)
  resumed.load_pack(ResumeForkExample::PACK)
  puts "[step 2] loaded #{resumed.run_id} — #{resumed.store.iter_events.size} events replayed"
  resumed.run_until_idle
  resumed.save_state
  resumed_graph = resumed.graph.not_nil!
  puts "[step 2] resumed to idle — #{resumed_graph.all_objects.size} objects, #{resumed_graph.all_relations.size} relations"

  # ---- step 3: fork at the first claim and inject a counter-hypothesis ----
  target = resumed_graph.events.find do |event|
    event.type == "object.created" && JSON.parse(event.payload)["type"]?.try(&.as_s?) == "claim"
  end
  raise "expected a claim to fork at" if target.nil?

  fork = resumed.fork(at_event: target.id, label: "alternative-thesis")
  fork_graph = fork.graph.not_nil!
  fork_graph.add_object("claim", %({"text":"Counter-hypothesis: market is saturated.","confidence":0.6,"evidence":[]}))
  fork.run_until_idle
  fork.save_state
  puts "[step 3] forked at #{target.id} -> #{fork.run_id} (#{fork_graph.all_objects.size} objects)"

  # ---- step 4: diff parent vs fork ---------------------------------------
  diff = resumed.diff(fork)
  puts "\n=== diff: parent vs fork ==="
  puts "  shared events:       #{diff.shared_events.size}"
  puts "  parent-only events:  #{diff.parent_only_events.size}"
  puts "  fork-only events:    #{diff.fork_only_events.size}"
  puts "  divergent objects:   #{diff.divergent_objects.size}"
  diff.divergent_objects.each { |obj| puts "    - #{obj.summary}" }
  puts "  divergent relations: #{diff.divergent_relations.size}"
  diff.divergent_relations.each { |rel| puts "    - #{rel.summary}" }

  File.delete(db) if File.exists?(db)
end

resume_and_fork_main
