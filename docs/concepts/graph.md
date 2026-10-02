# Graph

The graph is the world state of a Chronicle run. Objects sit on it as
typed nodes; relations connect them as typed edges. Behaviors react to
changes in the graph by emitting more changes. Goals are the inputs
operators push in from the outside.

The graph isn't a control-flow structure. It models what the system
**knows about**, not what the system **does next**. That's the
load-bearing distinction between Chronicle and workflow-graph frameworks
(LangGraph, the various DAG runners) — the nodes here are facts and
entities, not steps. Steps are behaviors, and behaviors live alongside
the graph, not inside it.

## Graph as projection of the event log

The graph is the projection of an append-only event log. Every mutation
— `add_object`, `patch_object`, `add_relation`, every behavior fire —
emits an event. The event lands in the store, and the graph in memory is
updated. Loading a run reconstructs the graph by replaying the events;
nothing else is persisted.

The projection is `Chronicle::GraphProjection`; the state it reads and
writes lives behind a `Chronicle::GraphStore` backend (in-memory by
default, SQLite/Postgres/FalkorDB behind the same seam). The projection
is copy-on-write, so apply/patch operations produce independent
snapshots.

This is the framework's most foundational invariant. Other concept pages
link here for it:

- [`events`](events.md) documents the event types that drive the
  projection.
- [`replay`](replay.md) is the operation that uses the projection
  property to reconstruct state.
- [`forking`](forking.md) creates a new run by copying a prefix of the
  event log; the forked graph is the projection of that prefix.
- [`failure-model`](failure-model.md) is why the framework refuses to
  silently produce events that don't represent real work — the
  projection would lie.

You can read the graph state at any time:

```crystal
graph.all_objects                         # every object
graph.objects(type: "claim")              # filtered by type
graph.relations(source: claim_id)         # outgoing edges
graph.relations(target: claim_id)         # incoming edges
graph.relations(type: "depends_on")       # by edge type
graph.get_object(object_id)               # by id, or nil
```

`graph.relations(source:, target:, type:)` is the canonical filter API;
all three arguments compose by AND, and calling with no arguments
returns every relation. `graph.get_relations(object_id:, type:,
direction:)` is a legacy alias preserved for compatibility.

`graph.objects(type:, where:)` additionally accepts a `where` hash of
dotted-path predicates using the same numeric-aware comparison semantics
as the pattern `WHERE` evaluator:

```crystal
graph.objects(type: "claim", where: {
  "confidence" => JSON::Any.new({">" => JSON::Any.new(0.5)}),
})
```

But you can't mutate it except through events. There's no
`graph.objects["x"] = ...` setter; every mutation goes through a method
that emits an event. `GraphProjection#emit` is the only live mutator.

## Objects

Objects are typed entities. The type is a string declared by the pack
that owns the object type (`@[ObjectType(name: "claim")]`) or any
string if no pack declares it. The data is **a canonical JSON string**:

```crystal
claim = graph.add_object("claim", %({
  "text": "Q3 revenue grew 28% YoY.",
  "confidence": 0.85
}))
claim.id    # => "claim#1"
JSON.parse(claim.data)["confidence"]   # => 0.85
```

`graph.add_object` returns the projected `Chronicle::GraphObject`
(`id`, `type`, `data`, `version`, `provenance`). Object ids are
framework-generated (`IDGen`), monotonic per run, and unique per run.
Object data is JSON-encodability-validated and otherwise opaque. When a
loaded pack declares a schema (a `JSON::Serializable` struct), the data
is validated at `add_object` time; a mismatch raises
`PackSchemaViolation` (see [`type-system`](type-system.md)).

### Divergence: JSON string data

Upstream stores object data as a Python `dict` and nests the object in
the `object.created` payload. Chronicle object/relation data are
canonical JSON strings, and the payload is flat (`id`, `type`, `data`,
`version`). Read data with `JSON.parse(obj.data)`; write it with
`JSON.build`, `.to_json`, or a serializable struct. See
[`plans/parity.md`](../../plans/parity.md).

## Relations

Relations are typed edges between objects. The type is a string, the
endpoints are object ids, and optional data is a JSON string on the edge
itself:

```crystal
graph.add_relation(claim.id, evidence.id, "supports", %({"strength": 0.9}))
```

`add_relation(source, target, type, data = "{}")` returns the projected
`Chronicle::GraphRelation` (`id`, `type`, `from_id`, `to_id`,
`provenance`). Relations have ids too (also framework-generated). A
relation type can carry a behavior — see
[`relations`](relations.md) for the distinction between passive, rule,
and agentic relations.

## Goals

Goals are the inputs operators push in from outside. A goal isn't an
object on the graph; it's an event of type `goal.created` that behaviors
subscribed to it react to:

```crystal
runtime.run_goal("Diligence: Northwind Robotics")
```

`run_goal` emits the `goal.created` event and drains registered pack
behaviors until the log quiesces (`run_until_idle`). Behaviors on
`goal.created` fire first; their output (objects, relations, more
events) triggers other behaviors, and the loop continues until the queue
is empty.

## What's NOT on the graph

- **Control flow.** The runtime's behavior dispatch is not modeled as
  graph nodes. The graph models the work product (objects, relations);
  behaviors are the framework's reactive code.
- **Configuration.** Pack settings, budget limits, the runtime's store
  URL — none of these are graph state. They're constructor arguments.
- **The event log itself.** The graph is a *projection* of the log; the
  log itself lives in the store. Read it via `graph.events`
  (in-memory) or `chronicle-cli log inspect` (operator-side).

## What's related

- [`events`](events.md) — the append-only history that drives the graph
  projection.
- [`behaviors`](behaviors.md) — the reactive code that mutates the graph
  in response to events.
- [`relations`](relations.md) — the typed-edge primitive and its
  optional behaviors.
- [`type-system`](type-system.md) — object/relation types and pack
  schema validation.
- [`failure-model`](failure-model.md) — why the framework refuses to
  silently bypass the event log.
