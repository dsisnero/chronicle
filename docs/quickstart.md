# Quickstart

From install to a working custom behavior. By the end of this
tutorial you'll have run the framework, written your own code in it,
saved a run, inspected it from the outside, and used the fork-and-diff
primitive that is specific to Chronicle and uncommon in other agent
frameworks. The steps build on each other; do them in order.

If you finish quickly, the tutorial isn't broken — you read faster than
the average. If something is rough, file an issue at
[GitHub](https://github.com/dsisnero/chronicle/issues) with where you
got stuck.

## 1. Install

```bash
shards install
make test
```

Crystal 1.21 or newer is required (declared in `shard.yml`). The bare
install includes the runtime, the in-memory and SQLite stores, and the
bundled Diligence pack. No API key is needed for this tutorial.

The runtime is built on [crig](https://github.com/dsisnero/crig) via
its hook system. Real LLM providers are reached through the Crig
`ModelExecutor` / `ProviderRegistry` seam; direct Anthropic/OpenAI
client classes are intentionally out of scope (see
[`plans/parity.md`](../plans/parity.md)).

## 2. Run the bundled demo

```bash
chronicle-cli quickstart
```

This runs the bundled Diligence pack against a scripted fixture
provider — one company, one diligence memo, no network, a few seconds.
The run is byte-deterministic; every machine produces the same output,
which is why the snapshot test for this command works.

You'll see several sections of output: a header naming the pack and
company, a trace, the produced memo rendered in full, and two prose
sections ("what just happened" and "try next"). Don't worry about
reading every trace line yet — step 3 is where we look at the trace.

The key beat: that memo came from nothing but a fixture-backed demo, in
seconds, with the same output on your machine as on mine. The
framework's pitch is "auditable agentic systems"; the deterministic
demo is that pitch made tangible.

## 3. Read the trace

Scroll back up to the trace block in the output. The lines tagged
`[goal.created]`, `[behavior.started]`, `[llm.requested]`,
`[object.created]`, and so on are **events** — the framework's
append-only record of everything that happened. Chronicle models the
world as a graph of objects connected by typed edges; events are how
the graph changes over time.

A few specific lines to find:

- `[pack.loaded]` near the top — when the Diligence pack registered its
  behaviors, tools, and prompt templates.
- `[goal.created]` — when the runtime received its first goal.
- A `[behavior.started]` for `diligence.company_planner` followed
  immediately by `[object.created] company#1` — the planner behavior
  fired in response to the goal and produced a `company` object on the
  graph.
- `[llm.requested]` and `[llm.responded]` pairs — every LLM call was
  served by the scripted fixture provider, so no network requests
  fired. In a production run through the Crig provider seam those would
  be real costs and real latencies.
- `[runtime.idle]` at the end of the goal's events — the runtime
  finished all the work it could do and stopped.

Two layers worth distinguishing now so the vocabulary lands cleanly
later: the **provider** is what produces LLM responses (here, the
scripted fixture; in production, a Crig completion model). The runtime's
**replay cache** is a separate layer that records `llm.responded`
events and serves them back when a run replays under strict-replay mode
or when `Runtime#fork(at_event:)` is called — that's where you'll see
`cache_hit` in the trace. See [`concepts/replay`](concepts/replay.md)
and [`concepts/forking`](concepts/forking.md) for the deep dive.

That trace is the framework's audit trail. The same artifact you just
read for fun is what you'd read while debugging a production incident.

We'll come back to events in more detail in
[`concepts/events`](concepts/events.md). For now: the trace is the
truth; everything else is a projection of it.

## 4. Write a custom behavior

The upstream interactive scaffold that writes a starter behavior to disk
is **not ported**; `chronicle-cli quickstart` is fixture-backed and
accepts only `cancel` / `quit` / `exit` on its input stream (see
`docs/development.md` and `plans/parity.md`). To write your own
behavior, define a pack. A **behavior** is the framework's unit of
reactive code — a Crystal method annotated with `@[Behavior]` that
subscribes to events and produces more events (new objects, new
relations, custom events).

Here is the equivalent of the quickstart's `growth_flagger`: flag any
`claim` whose confidence is above `0.25`. Create
`examples/my_first_behavior.cr`:

```crystal
require "./support/example_support"

module MyFirstBehavior
  include Chronicle::Packs::DSL

  @[Behavior(name: "growth_flagger", on: ["object.created"],
    where: {"type" => "claim"})]
  def growth_flagger(event : Chronicle::Event,
                     graph : Chronicle::GraphProjection,
                     ctx : Chronicle::Packs::BehaviorContext)
    payload = JSON.parse(event.payload).as_h
    data = payload["data"].as_h
    confidence = data["confidence"].as_f
    return unless confidence > 0.25

    graph.emit("growth.flagged", %({
      "claim_id": #{payload["id"].as_s.to_json},
      "confidence": #{confidence}
    }))
  end

  pack(name: "my_first_behavior", version: "0.1.0")
end
```

The shape to feel: an annotation declaring when it fires, and a method
body that reads from the event and writes to the graph. In Crystal the
annotation replaces upstream's `@behavior` decorator, and pack
registration happens at compile time via the `pack(...)` macro — there
are no Python decorators and no global registration. See
[`concepts/behaviors`](concepts/behaviors.md).

## 5. Run your behavior

Load the pack into a runtime and run the Diligence flow, then look for
your behavior's lines in the trace. The example driver mirrors
`examples/quickstart.cr`:

```crystal
model = ExampleSupport::ScriptedModel.new([...])
_store, graph, runtime = ExampleSupport.build(model)
runtime.load_pack(Chronicle::Packs::Diligence::PACK)
runtime.load_pack(MyFirstBehavior::PACK)

runtime.run_goal("Diligence: Northwind Robotics")
runtime.trace.lines.each { |line| puts line }
```

In the trace you'll find your behavior firing alongside the Diligence
pack's:

```text
[behavior.started]    my_first_behavior.growth_flagger
[event.emitted]       growth.flagged claim_id=claim#NN confidence=0.9
[behavior.completed]  my_first_behavior.growth_flagger
```

That's your code running in the same runtime as the Diligence pack,
firing on the same events, producing events downstream behaviors could
subscribe to. Your behavior is a first-class citizen of the graph —
there's no separate "user behavior" path.

Iterate by editing the file and re-running. For the full runnable
version, see `examples/quickstart.cr`.

## 6. Save and inspect

A SQLite-backed run saves itself. Open a runtime over a SQLite store,
or call `save_state` on an in-memory runtime to persist it:

```crystal
store = Chronicle::SQLiteEventStore.new("run.db", run_id: "quickstart")
runtime = Chronicle::Runtime(M).new(store: store, log_agent: log, graph: graph,
                                     run_id: "quickstart")
# ... run ...
runtime.save_state            # flush the attached SQLite store
runtime.save_state(path: "run.db")   # or late-bind a SQLite store
```

Then inspect it from the outside:

```bash
chronicle-cli log inspect --file run.db
chronicle-cli trace --file run.db --object claim#1
```

`log inspect` shows the run summary — run id, state, budget snapshot,
registered behaviors, and the tail of recent events. `trace` walks the
`caused_by` links from an object back to its goal. The same data the
trace showed, but as a query surface — you read it from outside the
run, which means you can read it after the run finishes, after the
process exits, after a restart.

`Runtime#save_state`, `Runtime#status`, and `Runtime#export_trace`
return Sans-IO values; the CLI is the edge that prints them.

## 7. Fork and diff

The closer. Forking is the framework's most differentiated capability.
A fork is a new run that shares the parent's event log up to a chosen
point, then diverges from there. Combined with a diff against the
parent, fork answers the question "what would have happened if I'd
configured this differently?"

The full fork-with-override workflow uses both a Crystal snippet and the
`chronicle-cli diff` command. The runtime form:

```crystal
require "chronicle"

db = "quickstart_demo_run.db"

# Pick the goal event for the first company as the fork point.
parent_store = Chronicle::SQLiteEventStore.new(db, run_id: "quickstart_demo_run")
fork_at = parent_store.iter_events.find { |e| e.type == "goal.created" }.not_nil!.id

# Load the parent and fork it. A fork needs a SQLite-backed runtime and
# a real event id; caches replay the shared prefix without provider calls.
agent = Crig::Agent(Model).new(model: model, preamble: "")
parent = Chronicle::Runtime(Model).load(db, "quickstart_demo_run", agent,
                                        replay_embedding_cache: true)
fork = parent.fork(at_event: fork_at, label: "cautious",
                   replay_llm_cache: true, replay_tool_cache: true)

# Load a differently-configured pack into the fork and run it.
fork.load_pack(Chronicle::Packs::Diligence::PACK,
               {"confidence_threshold_for_review" => JSON::Any.new(0.9)})
fork.run_until_idle
fork.save_state

# Structural diff: shared prefix + each side's tail + divergent entities.
diff = parent.diff(fork)
puts "shared:           #{diff.shared_events.size}"
puts "parent-only:      #{diff.parent_only_events.size}"
puts "fork-only:        #{diff.fork_only_events.size}"
puts "divergent objs:   #{diff.divergent_objects.size}"
diff.divergent_objects.first(5).each { |d| puts "  - #{d.summary}" }
```

The same primitive from the CLI reads the event log files directly:

```bash
chronicle-cli diff --before parent.log --after fork.log
```

You'll see five counts (shared events, parent-only events, fork-only
events, divergent objects, divergent relations) and a list of objects
that exist in both runs with different state. The first divergent
object is where the threshold change started producing different work.

`Runtime#diff` is structural only — divergent objects, divergent
relations, and the event partition (shared prefix, parent-only tail,
fork-only tail). Semantic comparison is a behavior's job, not the
runtime's.

What you just did: ran the same starting state through a different
decision, and got a structural comparison of the results. Hypothesis
testing on an agentic system, without losing the parent run.

For the conceptual deep-dive on forks (shared lineage, cache replay,
the strict-vs-permissive replay distinction), read
[`concepts/forking`](concepts/forking.md).

Two requirements, both enforced with structured errors: `fork()` needs a
SQLite-backed runtime (`IncompatibleRuntimeState`), and `at_event=` must
be a real event id from the parent's log.

## What to read next

You've now run the framework, written your own behavior, persisted a
run, queried it from outside, and forked it. That's the loop; everything
else is depth on one of these primitives.

In rough order of usefulness from here:

- [`concepts/graph`](concepts/graph.md) and
  [`concepts/behaviors`](concepts/behaviors.md) — the mental model. Read
  both in one sitting; together they take about fifteen minutes.
- [`concepts/events`](concepts/events.md) — the append-only history and
  the flat-payload divergence from upstream.
- [`concepts/failure-model`](concepts/failure-model.md) — the
  framework's stance on what counts as a recoverable failure. Short,
  load-bearing, worth reading once.
- [`concepts/type-system`](concepts/type-system.md) — the framework
  event vocabulary, developer-defined object/relation types, and the
  patch lifecycle.
- [`plans/parity.md`](../plans/parity.md) — what is ported and what is
  deferred.
