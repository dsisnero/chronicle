# Events

An event is an immutable record of something that happened in a run.
Events are append-only — once an event lands in the store, nothing
modifies it. The graph state is a projection of the event log (see
[`graph`](graph.md)); behaviors fire by subscribing to events and
producing more events.

The event log is the source of truth. Everything else — the graph, the
trace, the audit history — is derived from it.

## The structure

An event is a `Chronicle::Event`, an immutable Crystal struct with:

- `id` — framework-generated, monotonic per run, unique per run.
- `sequence` — the append position. **The store is the sequencing
  authority** (see the divergence note below).
- `type` — a string discriminator. Framework events use a dotted
  namespace (`object.created`, `behavior.completed`, `runtime.idle`);
  user code emits custom types via `graph.emit` (any string is valid,
  but the dot-namespaced convention is recommended).
- `payload` — a **canonical JSON string**. The framework validates JSON
  encodability at emit time.
- `actor` — who or what produced the event. `"user"` for goals pushed
  in from outside, `"runtime"` for framework-emitted events, a behavior
  name for behavior-emitted events.
- `caused_by` — the id of the event that triggered the behavior that
  produced this one. The causal chain is reconstructable by walking
  `caused_by` back to a root event (`goal.created`, typically).
- `frame_id` — the frame the event belongs to, or `nil`.
- `schema_version` — the envelope schema version (`1_u16`).
- `timestamp` — ISO 8601, set at emit time. Used for the trace display;
  behavior bodies must not depend on it for determinism (see
  [`behaviors`](behaviors.md) — the determinism contract).

```crystal
event = Chronicle::Event.new(
  schema_version: 1_u16,
  sequence: 1_u64,
  id: "evt_001",
  type: "goal.created",
  actor: "user",
  caused_by: nil,
  payload: %({"goal":"Evaluate this startup idea"}),
)
```

### Divergence: flat payloads and store-stamped sequence

Upstream activegraph nests an object under `"object"` inside
`object.created` payloads. Chronicle uses **flat payloads**: an
`object.created` payload carries `id`, `type`, `data`, and `version` at
the top level, and `data` is a canonical JSON string (not a Python
dict). `data` is a string in Crystal because the object model is
JSON-first; read it with `JSON.parse(obj.data)`.

The store, not the emitter, stamps `sequence` on append. A
`GraphProjection` may build a provisional sequence, but
`MemoryEventStore`, `SQLiteEventStore`, and `PostgresEventStore` all
replace it with the store-assigned append position so the log is always
strictly increasing and directly codec-encodable. See
[`plans/parity.md`](../../plans/parity.md) and
[`docs/architecture.md`](../architecture.md).

## The framework event types

Events emitted by the runtime itself fall into a small set of families:

- **Lifecycle**: `goal.created`, `runtime.idle`,
  `runtime.budget_exhausted` — boundary events around a run.
- **Object mutations**: `object.created`, `object.removed` — object
  birth and removal. (The projection also accepts `object.patched`.)
- **Relation mutations**: `relation.created`, `relation.removed`.
- **Behavior dispatch**: `behavior.started`, `behavior.completed`,
  `behavior.failed`, `behavior.scheduled`,
  `relation_behavior.started` — what the runtime did while running
  behaviors.
- **Context reads** (opt-in on the runtime): `context.read` — one
  batched event per behavior execution carrying the ordered,
  deduplicated object ids the behavior read. Like `behavior.*`, it never
  schedules behaviors.
- **Pattern matching**: `pattern.matched` — emitted before
  `behavior.started` when the behavior used a pattern subscription;
  carries the match count.
- **LLM / tool**: `llm.requested`, `llm.responded`, `tool.requested`,
  `tool.responded` — every LLM call and every tool call appears as a
  request/response pair. A successful `llm.responded` carries the model
  output. **Divergence:** upstream records a failed transient attempt as
  `llm.responded` with an `error` payload; Chronicle records a distinct
  `llm.failed` event (whose `caused_by` is the failed `llm.requested`)
  and retries in place.
- **Patches**: `patch.proposed`, `patch.applied`, `patch.rejected` —
  the patch lifecycle. Direct `graph.patch_object(...)` shortcuts also
  emit `patch.applied`.
- **Approvals**: `approval.proposed`, `approval.granted` — the
  policy-gated approval lifecycle. **Divergence:** the upstream
  `approval.denied` event is not emitted; denial is resolved at the
  edge through `ApprovalAdapter` and a nonexistent approval id raises
  `ApprovalError`.
- **Pack lifecycle**: `pack.loaded`, `pack.settings_overridden` —
  `pack.loaded` is emitted once per `runtime.load_pack` call and
  carries the pack name, version, settings, and prompt content hashes.
  `pack.settings_overridden` records fork-local overrides; the parent
  prefix stays append-only, and pack loading applies the override before
  post-fork execution resumes.
- **Compaction / promotion**: `runtime.snapshot` (a compacted prefix)
  and `promote.applied` (a promote marker) are recorded runtime
  actions. See [replay](replay.md) and
  [`plans/parity.md`](../../plans/parity.md).

Custom event types from user code live alongside these and follow the
same shape. Behaviors subscribe to either set with the same `on:`
annotation argument.

## Append-only and what that means

Once an event is in the store, it doesn't change. No edit, no delete,
no truncate (except via the explicit `truncate_after` primitive, which
is operator-side, not behavior-side). This is the property that makes
replay work: loading a run reads the event log and produces the same
graph state every time.

Three consequences:

- **There's no "current value" of an object outside its event
  history.** An object's data is the result of applying every
  `object.created` and `patch.applied` event for that object id, in
  order. The `GraphObject` in memory is a cache of that computation, not
  an authoritative store.
- **Operations that look like mutations are emissions.** `add_object`
  emits `object.created`; `patch_object` emits `patch.applied`;
  `remove_object` emits `object.removed`. The graph in memory updates as
  a side effect of the emit. `GraphProjection#emit` is the single
  mutation path, and a store-attached projection's `graph.events` is the
  full run log.
- **The audit trail is automatic.** Anything that happened in a run is
  in the event log. Nothing else is needed for audit — there's no
  separate audit-log subsystem because the event log is the audit log.

## Events vs exceptions

The framework distinguishes two failure modes: exceptions for
caller-actionable problems the caller can catch at the call site, and
events for non-fatal stops the audit trail should record and the runtime
should continue past. Behavior failures, tool failures, budget
exhaustion, and approval denials are events. Construction errors, lookup
misses, replay divergence, and pattern syntax errors are exceptions.

See [`failure-model`](failure-model.md) for the full principle and why
the framework treats them differently.

## Reading the event log

The event log is available three ways:

```crystal
# In-memory, current run: the projection accumulates every applied event.
graph.events.each { |event| puts event.type }

# From the store, by run id:
store = Chronicle::SQLiteEventStore.new("run.db", run_id: "default")
store.iter_events.each { |event| puts event.type }
store.get_event("evt_006")   # one event by id

# CLI, operator-side:
# chronicle-cli log inspect --file run.db
# chronicle-cli trace --file run.db --object claim#1
```

The trace (`runtime.trace.lines`, or `chronicle-cli trace`) is the
human-readable projection of the event log — same data, formatted with
tags and short summaries for visual scanning. The trace is
informational; the events are the data.

## What's related

- [`graph`](graph.md) — the projection of the event log. Owns the
  "graph as projection" principle.
- [`behaviors`](behaviors.md) — the reactive code that subscribes to
  events.
- [`failure-model`](failure-model.md) — the events-vs-exceptions
  distinction.
- [`replay`](replay.md) — the operation that uses the append-only
  property to reconstruct state.
