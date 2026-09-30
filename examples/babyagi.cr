require "./support/example_support"

# Port of vendor/activegraph/examples/babyagi.py: BabyAGI's autonomous agent
# loop rebuilt as reactive behaviors over the shared graph.
#
#   original step          becomes                   reacts to
#   ----------------       -------------------       ---------------
#   seed the first task    initializer              goal.created
#   execute current task   executor (LLM)           object.created (task)
#   generate follow-ups    task_creator (LLM)       task.executed
#
# The loop is event propagation: as long as new task objects land, `executor`
# fires again. An empty follow-up list is how it terminates. The frame carries
# the objective and constraints into every LLM call's system prompt.

module BabyAgiExample
  include Chronicle::Packs::DSL

  struct TaskResult
    include JSON::Serializable
    property result : String
  end

  struct NewTasks
    include JSON::Serializable
    property tasks : Array(String)
  end

  @[Behavior(name: "initializer", on: ["goal.created"])]
  def initializer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    goal = JSON.parse(event.payload)["goal"].as_s
    graph.add_object("task", %({"title":#{("Plan the first step toward: " + goal).to_json},"status":"pending"}))
  end

  @[LLMBehavior(name: "executor", on: ["object.created"], where: {"type" => "task"},
    output_schema: TaskResult, creates: ["result"],
    description: "You are the EXECUTION agent in a BabyAGI loop. Carry out the task concretely. Do NOT plan further steps — another behavior handles that.")]
  def executor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, llm_output : TaskResult)
    payload = JSON.parse(event.payload).as_h
    return unless payload["data"].as_h["status"].as_s == "pending"
    task_id = payload["id"].as_s
    graph.patch_object(task_id, %({"status":"completed"}))
    result = graph.add_object("result", %({"task_id":#{task_id.to_json},"content":#{llm_output.result.to_json}}))
    graph.add_relation(task_id, result.id, "produced")
    ExampleSupport.emit(graph, "task.executed", %({"task_id":#{task_id.to_json},"result":#{llm_output.result.to_json}}))
  end

  @[LLMBehavior(name: "task_creator", on: ["task.executed"],
    output_schema: NewTasks, creates: ["task"],
    description: "You are the TASK-CREATION agent in a BabyAGI loop. Propose 0-4 follow-ups. Return an empty list ONLY when the objective is fully accomplished.")]
  def task_creator(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, llm_output : NewTasks)
    llm_output.tasks.each do |title|
      next if title.strip.empty?
      graph.add_object("task", %({"title":#{title.strip.to_json},"status":"pending"}))
    end
  end

  pack(name: "babyagi", version: "0.1.0")
end

def babyagi_main
  objective = "Plan a 3-day intro to Rust programming"
  constraints = [
    "Be specific and actionable — avoid vague generalities.",
    "Build incrementally on previous results rather than repeating them.",
  ]

  # Four scripted turns: execute task 1, propose one follow-up, execute it, then
  # report that the objective is complete (empty list terminates the loop).
  model = ExampleSupport::ScriptedModel.new([
    %({"result":"First, install the Rust toolchain with rustup and write a hello-world crate."}),
    %({"tasks":["Draft a 3-day schedule covering ownership and error handling"]}),
    %({"result":"Day 1: syntax and ownership basics. Day 2: error handling. Day 3: a small CLI project."}),
    %({"tasks":[]}),
  ])

  db = File.join(Dir.tempdir, "chronicle_babyagi_trace.db")
  File.delete(db) if File.exists?(db)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "babyagi")
  _evt_store, _graph, runtime = ExampleSupport.build(model, store: store, run_id: "babyagi")
  runtime.load_pack(BabyAgiExample::PACK)
  runtime.push_frame(Chronicle::Frame.new(goal: objective, constraints: constraints))

  runtime.run_goal(objective)
  runtime.save_state

  puts "trace: #{db}"
  puts "inspect with: crystal run src/chronicle/cli_main.cr -- log inspect -f #{db}"
  puts
  ExampleSupport.print_trace(runtime)

  File.delete(db) if File.exists?(db)
end

babyagi_main
