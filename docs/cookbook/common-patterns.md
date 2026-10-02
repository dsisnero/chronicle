# Common patterns

Recurring idioms with copy-pasteable code. Each pattern is one
sub-section: the code, a short rationale, and a pointer at the concept
page that owns the underlying primitive.

If you're writing a new behavior and one of these patterns fits, use it
— the patterns are how the framework's primitives compose to solve the
everyday shapes that come up in agentic systems. If none of them fit,
you're probably reaching for a primitive in a new way, and the rest of
the docs are the right next stop.

> **Port note.** Crystal pack behaviors are declared with annotations and
> collected by `pack(...)`; runtime wiring is generic (`Chronicle::Runtime(M)`).
> The examples below assume a module that `include Chronicle::Packs::DSL`
> and a runtime constructed as shown in the README.

## Retry behaviors on transient failures

The canonical pattern for handling terminal LLM or tool failures that
are non-deterministic (network errors, rate limits, timeouts). LLM
provider-call transients (`llm.network_error`, `llm.rate_limited`)
already get a small bounded retry loop inside the runtime; only the
exhausted terminal failure reaches `behavior.failed`. `behavior.failed`
events carry the original `reason` code, so a retry behavior can
subscribe to them and gate on the codes that warrant a higher-level
retry:

```crystal
@[Behavior(name: "retry_transient", on: ["behavior.failed"])]
def retry_transient(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  payload = JSON.parse(event.payload).as_h
  reason = payload["reason"]?.try(&.as_s?)
  return unless reason.in?(%w(llm.network_error llm.rate_limited tool.timeout tool.network_error))

  attempt = (payload["attempt"]?.try(&.as_i?) || 0) + 1
  return if attempt > 3

  graph.emit("retry.requested", JSON.build do |json|
    json.object do
      json.field "for_event", payload["event_id"]?.try(&.as_s?)
      json.field "attempt", attempt
      json.field "behavior", payload["behavior"]?.try(&.as_s?)
    end
  end)
end
```

Retries are first-class graph citizens (CONTRACT v0.6 #13). Runtime LLM
attempts appear as `llm.requested` / `llm.responded` pairs; terminal
retry behavior events appear in the trace and can be forked from.
Per-behavior caps live in the behavior body; the framework's built-in
provider-call retry is intentionally small.

`behavior.failed` is an event, not an exception that escapes to your
code. Read it with `runtime.errors` (structured `BehaviorFailure`
values) or by filtering `runtime.trace.events`.

## Fork-and-diff to compare alternative hypotheses

When you want to know "what would happen if I changed this setting,"
fork from a point before the setting takes effect, run the fork with the
override, and diff.

```bash
# Find the sequence before the setting matters.
chronicle-cli log inspect -f run.log

# Fork the encoded log at that sequence.
chronicle-cli fork -f run.log -a 42 -o cautious.log

# Diff the two logs.
chronicle-cli diff -a run.log -b cautious.log
```

The diff prints shared events, parent-only events, fork-only events, and
divergent objects. The first divergent object tells you where the
override started producing different work. For a live, lineage-aware
fork (and pack-setting overrides), use the library form below.

## Fork with a pack-setting override

Use the library API when your application already owns runtime
construction or needs to compute settings directly. It copies the
parent's events up to the fork point, then resumes execution under
different pack settings.

```crystal
parent_path = "/tmp/chronicle_quickstart/quickstart_demo_run.db"
parent_run  = "quickstart_demo_run"
fork_run    = "quickstart_cautious_fork"

# Find a fork point — typically the goal.created event for the
# company you want to re-run with the override.
parent_store = Chronicle::SQLiteEventStore.new(parent_path, run_id: parent_run)
fork_at = parent_store.iter_events.find { |e| e.type == "goal.created" }.not_nil!.id

# Copy parent events up to the fork point into the new run.
Chronicle::SQLiteEventStore.fork_run(
  path: parent_path,
  parent_run_id: parent_run,
  new_run_id: fork_run,
  at_event_id: fork_at,
  label: "cautious",
  created_at: Time.utc.to_rfc3339,
)

# Load the fork and run it with the override settings.
fork_rt = Chronicle::Runtime(MyModel).load(parent_path, fork_run, agent)
fork_rt.load_pack(
  Chronicle::Packs::Diligence::PACK,
  settings: {"confidence_threshold_for_review" => JSON::Any.new(0.9)}, # ← override (was 0.7)
)
fork_rt.run_until_idle
fork_rt.save_state
```

The library diff is the same call used for any run pair:

```crystal
parent_rt = Chronicle::Runtime(MyModel).load(parent_path, parent_run, agent)
diff = parent_rt.diff(fork_rt)
puts diff.divergent_objects.map(&.summary)
```

The diff shows the structural difference produced by the threshold
change. For operator workflows, prefer the CLI form above; for embedded
application code, keep the library form.

## Pattern subscriptions for cross-object reactivity

When a behavior should fire only when a specific structural
relationship exists in the graph, use a pattern subscription instead of
an event-type filter:

```crystal
@[Behavior(
  name: "risk_escalator",
  pattern: "(c:claim)-[:supports]->(e:evidence) WHERE c.confidence > 0.7",
)]
def risk_escalator(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  ctx.matches.each do |match|
    claim_id = match["c"]
    evidence_id = match["e"]
    # ...
  end
end
```

The pattern matcher reads the full graph; the behavior body operates on
`ctx.matches`, one entry per binding combination that satisfies the
pattern. The handler fires once per event regardless of how many
bindings the pattern produced. Anything outside the locked Cypher
subset is refused at parse time with `UnsupportedPatternError`.

## `ctx.propose_object` for policy-gated writes

When an object should require approval before landing — memos, risks,
anything an operator should review — use `ctx.propose_object` instead of
`graph.add_object`:

```crystal
@[Behavior(name: "memo_synthesizer", on: ["claims.complete"])]
def memo_synthesizer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  # ...
  ctx.propose_object(
    "memo",
    %({"title":"Diligence memo","body":"..."}),
    reason: "diligence run complete",
  )
end
```

The proposal lands as `approval.proposed`. If the pack's auto-approve
setting is on, the framework approves immediately and the object lands.
If off, the proposal sits until `runtime.approve_pack(id)` is called.

The operator-side enumeration pattern:

```crystal
runtime.pack_pending_approvals.each do |pa|
  puts "#{pa.id} #{pa.kind} #{pa.object_type} #{pa.reason}"
  runtime.approve_pack(pa.id, approved_by: "reviewer")
end
```

See `examples/diligence_real_run.cr` for a runnable approval-flow demo.

## Scoped views for cost-efficient LLM behaviors

When an LLM behavior only needs to read a few neighbors of the
triggering object, narrow the view to bound prompt size and cost:

```crystal
@[LLMBehavior(
  name: "claim_summarizer",
  on: ["object.created"],
  where: {"type" => "claim"},
  view: {around: "id", depth: 1},
)]
def claim_summarizer(event, graph, ctx, output : String)
  payload = JSON.parse(event.payload).as_h
  claim = ctx.view.objects.find { |obj| obj.id == payload["id"].as_s }
  ctx.view.objects.each do |neighbor|
    # ...
  end
end
```

`around` + `depth` scope what `ctx.view` returns. `around` is a path
into the triggering event's **flat** payload (e.g. `"id"`), not the
nested `event.payload.object.id` upstream uses. The prompt assembler
serializes the view; smaller view, smaller prompt. LLM behaviors that
pass the full graph to the prompt assembler are the canonical source of
unbounded cost growth in agentic systems — scoping is the answer.

## `@[RelationBehavior]` for coordination logic between endpoints

When the logic semantically belongs to a relationship, not to either
endpoint, use `@[RelationBehavior]`:

```crystal
@[RelationBehavior(
  name: "auto_unblock",
  relation_type: "depends_on",
  on: ["task.completed"],
)]
def auto_unblock(relation : Chronicle::GraphRelation, event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  payload = JSON.parse(event.payload).as_h
  if payload["task_id"]?.try(&.as_s?) == relation.from_id
    graph.patch_object(relation.to_id, %({"status":"open"}))
  end
end
```

The behavior fires once per matching edge.

## Emit a custom event for cross-behavior signaling

When two behaviors need to coordinate but neither owns the trigger,
emit a custom event from one and subscribe from the other:

```crystal
@[Behavior(name: "produce", on: ["object.created"])]
def produce(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  # ...
  graph.emit("memo.ready_for_review", %({"memo_id":#{memo_id.to_json}}))
end

@[Behavior(name: "review", on: ["memo.ready_for_review"])]
def review(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  # ...
end
```

Custom event names use dot-namespace convention (`my.feature.event`);
behaviors subscribing by name pick them up. The events land in the trace
alongside framework events.

## Save state across processes

When a long-running goal needs to survive process restart, attach a
SQLite store and call `save_state` at quiescence:

```crystal
store = Chronicle::SQLiteEventStore.new("/path/to/run.db", run_id: "run-1")
graph = Chronicle::GraphProjection.empty.attach_store(store)
agent = Crig::Agent(MyModel).new(model: MyModel.new, preamble: "")
log_agent = Chronicle::LogAgent(MyModel).new(agent, store: store)
rt = Chronicle::Runtime(MyModel).new(store: store, log_agent: log_agent, graph: graph, run_id: "run-1")

rt.run_goal("...")
rt.save_state
```

To resume later:

```crystal
rt = Chronicle::Runtime(MyModel).load("/path/to/run.db", "run-1", agent)
rt.run_until_idle
```

Restoring loads the event log and replays it. Behaviors fire fresh after
the replay; the framework treats them as a continuation of the original
run. Operationally, persist to a SQLite path (or a connection URL via
`Chronicle.open_store`); see
[Operating in production](../guides/operating-in-production.md) for the
full operator-facing surface.
