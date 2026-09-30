require "./support/example_support"

# Port of vendor/activegraph/examples/operate_a_run.py (the v0.8 contract):
# the operator loop. Start a persisted run, run partway, take a `status`
# snapshot, inspect/fork/diff from the CLI, export the trace as JSONL, and
# show the migration seam.
#
# Port divergence: the Crystal CLI operates on encoded event-log files
# (`EventLogCodec`) rather than store URLs, and its `fork`/`diff` subcommands
# are log-to-log. The runtime library fork (SQLite, lineage-aware) is used for
# the live branch, then both logs are exported for the CLI diff. Postgres
# migration is deferred upstream in this port, so `migrate` is reported as
# skipped unless `CHRONICLE_MIGRATE_TO` names a destination SQLite URL.

module OperateExample
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

  pack(name: "operate", version: "0.1.0")
end

# Encode a runtime's event log to the CLI's newline-delimited format. A run's
# merged log is strictly increasing (runtime and graph events share one
# monotonic sequence), so it encodes directly.
def write_cli_log(path : String, events : Array(Chronicle::Event)) : Nil
  File.write(path, Chronicle::EventLogCodec.encode(Chronicle::EventLog.from_events(events)))
end

def operate_a_run_main
  work = Dir.tempdir
  db = File.join(work, "chronicle_operate.db")
  parent_log = File.join(work, "chronicle_operate_parent.log")
  fork_log = File.join(work, "chronicle_operate_fork.log")
  parent_jsonl = File.join(work, "chronicle_operate_parent.jsonl")
  [db, parent_log, fork_log, parent_jsonl].each { |path| File.delete(path) if File.exists?(path) }

  # ---- setup: observability + persistent store ----------------------------
  metrics = Chronicle::PrometheusMetrics.new
  model = ExampleSupport::ScriptedModel.new([] of String)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "ops-demo")
  _evt_store, graph, runtime = ExampleSupport.build(model, store: store, run_id: "ops-demo", metrics: metrics)
  runtime.load_pack(OperateExample::PACK)
  puts "[setup] metrics=PrometheusMetrics store=#{db}"

  # ---- run partway, then take the frozen status snapshot ------------------
  runtime.run_goal("Evaluate this startup idea")
  runtime.save_state
  status = runtime.status
  puts "\n[runtime.status snapshot]"
  puts "  run_id           = #{status.run_id}"
  puts "  state            = #{status.state.to_s.downcase}"
  puts "  queue_depth      = #{status.queue_depth}"
  puts "  events_processed = #{status.events_processed}"
  puts "  behaviors        = #{status.registered_behaviors.map(&.name)}"

  # ---- inspect from the CLI ------------------------------------------------
  write_cli_log(parent_log, runtime.store.iter_events)
  puts "\n[cli] inspect from the shell:"
  puts Chronicle::CLI.run(["log", "inspect", "-f", parent_log]).lines.first(4).join("\n")

  # ---- branch: library fork, then run both sides to completion ------------
  fork_at = graph.events.find { |event| event.type == "object.created" }.not_nil!
  fork = runtime.fork(at_event: fork_at.id, label: "ops-demo-fork")
  fork.run_until_idle
  fork.save_state
  runtime.run_until_idle
  runtime.save_state
  puts "\n[cli] forked at #{fork_at.id} -> #{fork.run_id}"

  # ---- diff from the CLI (encoded logs) -----------------------------------
  write_cli_log(parent_log, runtime.store.iter_events)
  write_cli_log(fork_log, fork.store.iter_events)
  puts "\n[cli] diff parent vs fork:"
  puts Chronicle::CLI.run(["diff", "-a", parent_log, "-b", fork_log])

  # ---- export the trace as JSONL for log aggregation ----------------------
  File.open(parent_jsonl, "w") do |io|
    runtime.store.iter_events.each { |event| io.puts event.canonical_json }
  end
  line_count = File.read_lines(parent_jsonl).size
  puts "\n[cli] export trace as JSONL to #{parent_jsonl}: wrote #{line_count} lines"

  # ---- migration seam ------------------------------------------------------
  if dest = ENV["CHRONICLE_MIGRATE_TO"]?
    report = Chronicle::Migration.migrate("sqlite://#{db}", "sqlite://#{dest}")
    puts "\n[cli] migrate #{db} -> #{dest}:"
    report.runs.each { |run| puts "  #{run.status} run=#{run.run_id} events=#{run.events_migrated}" }
  else
    puts "\n[migrate] skipped — set CHRONICLE_MIGRATE_TO to a SQLite path to demo the sqlite→sqlite port"
  end

  [db, parent_log, fork_log, parent_jsonl].each { |path| File.delete(path) if File.exists?(path) }
  puts "\n[done]"
end

operate_a_run_main
