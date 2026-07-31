# Chronicle

> The graph is the world. Behaviors are physics. The trace is the proof.

An event-sourced reactive graph runtime for long-running, auditable,
agentic systems — a Crystal port of
[activegraph](https://github.com/yoheinakajima/activegraph), the reference
implementation of the design in
["The Log is the Agent"](https://arxiv.org/abs/2605.21997).

Behaviors react to a shared graph instead of talking to each other. Every
change is an event; the trace is the audit trail. Every run is resumable,
forkable, and diff-able from its event log.

If chat-based agents are a group conversation, Chronicle is a shared
workspace where everyone can see what changed, who changed it, and why.

## What you get

- **Event-sourced graph runtime.** Objects + typed relations + an
  append-only event log. Every mutation is an event; the trace is the
  audit trail.
- **A strict Cypher subset for pattern subscriptions.** Node and
  relationship patterns, multi-hop chains, `WHERE` with `AND`/`NOT`/
  `NOT EXISTS`, and property equality — anything outside the locked
  subset is refused at parse time with an actionable
  `UnsupportedPatternError`. `Chronicle.parse(...).compile.matches(event, graph)`
  is the whole surface.
- **GraphStore backends.** The materialized projection lives behind a
  pluggable `GraphStore` seam: an in-memory default and a SQLite-backed
  store, both pinned by a reusable conformance suite.
- **Fork-and-diff.** Branch any run at any event into an independent
  fork and structurally diff the result against the parent. The LLM
  replay cache makes forked/replayed runs cheap — recorded responses are
  served by request hash with no provider calls.
- **Deterministic router.** Only routing must be deterministic: a pure
  function of policy, intent, and context that emits a `routing.decided`
  receipt before any model call, with ordered fallback on retryable
  failures.
- **Runtime concerns as first-class ports.** Budgets, pending approvals,
  an authority ceiling, bounded run quanta, frame scoping, pack loading
  with per-behavior policies, and structured trace/status output.
- **Sans-IO sinks.** Accepted events flow to bounded outbound observers
  (`JSONLSink`, testing sinks) with overflow policy and status accounting,
  without adapter I/O on the core's hot path.

## Try it

```bash
shards install
make test
```

Then run the examples:

```bash
crystal run examples/deepseek_routing.cr
crystal run examples/save_patch_replay.cr
```

A tiny program — build a graph, then ask the Cypher subset for matches:

```crystal
require "chronicle"

graph = Chronicle::GraphProjection.empty
claim = graph.add_object("claim", %({"text":"Market early but growing.","confidence":0.7}))
doc   = graph.add_object("doc",   %({"title":"Research"}))
graph.add_relation(claim.id, doc.id, "supports")

matcher = Chronicle.parse(
  "(c:claim)-[:supports]->(d:doc) WHERE c.confidence > 0.5"
).compile
matcher.matches(nil, graph).each do |m|
  puts "claim #{m["c"]} supports doc #{m["d"]}"
end
```

## Install

Add the shard to your `shard.yml`:

```yaml
dependencies:
  chronicle:
    github: dsisnero/chronicle
```

then `shards install`, and `require "chronicle"` from Crystal code.

## Concepts at a glance

The primitives, in roughly the order you meet them when reading a trace:

- **Event** — the immutable, append-only unit of history: schema version,
  sequence, id, type, actor, `caused_by`, optional `frame_id`, timestamp,
  and a canonical JSON payload.
- **EventLog** — append-only, enforces sequence/causality invariants;
  serialized by a versioned newline-delimited codec and persisted by an
  `EventStore` (in-memory or SQLite).
- **GraphProjection** — objects and typed relations folded from events.
  Read surface: `objects(type:, where:)`, `relations(source:, target:, type:)`,
  `neighborhood`, `match_chain`, `diff`. Write surface: `add_object`,
  `add_relation`, `remove_*`, `emit` with listeners and sinks.
- **GraphStore** — the pluggable backend seam behind the projection;
  `InMemoryGraphStore` (default) and `SQLiteGraphStore`, both passing a
  reusable conformance suite.
- **Patterns** — the strict Cypher subset for graph-shape subscriptions,
  with a WHERE evaluator over the same JSON comparison semantics used by
  the graph query API.
- **Patches** — proposed mutations with optimistic concurrency
  (`proposed → applied | rejected`) checked against `expected_version`.
- **Views** — scoped reads (`around`, `include_types`, `recent_events`)
  built from the projection.
- **IDGen** — global monotonic ids (`task#1`, `task#2`, `claim#3`),
  `evt_/rel_/patch_/frame_` sequences, and `run`/ULID.
- **Runtime / LogAgent** — drives the model/tool loop over
  [crig](https://github.com/dsisnero/crig) with a recording hook; owns the
  budget, routing, approvals, authority ceiling, run quanta, frames, packs,
  and trace/status output.
- **LLM replay cache** — serves recorded `llm.responded` results by
  request hash during replay/fork; `replay_strict` raises
  `ReplayDivergenceError` on prompt-hash mismatch.
- **Tools** — `Tool`/`ToolRegistry`, a `graph_query` tool bound to a
  projection, `tool.requested`/`tool.responded` recording, and a
  `ToolCache` for replay.
- **Sinks** — bounded outbound observers of accepted events with overflow
  policy and status accounting.
- **Frames** — bounded contexts for a run; events carry a `frame_id`.
- **Packs** — bundles of object types, tools, and per-behavior policies;
  `load_pack` registers tools and routes policy-required tool calls through
  pending approval.
- **Replay** — reconstruct state from the event log; strict mode compares
  the emitted stream and reports divergence; permissive mode reconstructs
  without re-firing.
- **Fork** — branch an `EventLog` at any sequence point.
- **Trace** — `Trace.causal_chain` walks `caused_by` links from an object
  back to its goal; the CLI renders it (`chronicle-cli trace --file --object`).

## Type system at a glance

**Event types — fixed.** The runtime emits these; the trace and replay
key off them.

- Lifecycle: `goal.created`, `budget.exhausted`, `pack.loaded`
- Graph: `object.created`, `object.removed`, `relation.created`, `relation.removed`
- LLM: `llm.requested`, `llm.responded`, `llm.failed`
- Tools: `tool.requested`, `tool.responded`
- Patches: `patch.proposed`, `patch.applied`, `patch.rejected`
- Routing: `routing.decided`, `routing.fallback_selected`

**Object and relation types — yours.** Any string works; no central
schema or registration step. `graph.add_object("claim", ...)` creates a
`claim` because you said `claim`. Object and relation data are canonical
JSON strings; the query API and patterns read them with the same
numeric-aware comparison semantics.

**Patch states — fixed.** `proposed → applied | rejected`.

## Documentation

- [docs/architecture.md](docs/architecture.md) — the log-primary,
  Sans-IO architecture and module map.
- [docs/development.md](docs/development.md) — local commands and gates.
- [docs/coding-guidelines.md](docs/coding-guidelines.md) — Crystal idioms
  and repo conventions.
- [docs/testing.md](docs/testing.md) — the deterministic test discipline.
- [docs/pr-workflow.md](docs/pr-workflow.md) — contribution workflow.
- [CHANGELOG.md](CHANGELOG.md) — release history.
- [plans/parity.md](plans/parity.md) — the activegraph parity plan and
  per-phase tracking.

## What this is not

- Not a chat framework. If your problem fits in one conversation, use a
  chat framework.
- Not a workflow engine. Workflows model control flow. This models world
  state.
- Not a rules engine, exactly. Rules engines forward-chain over facts.
  This event-sources over a graph and supports LLM behaviors as
  first-class.
- Not magic. Bad behaviors produce bad graphs. The runtime makes the
  badness inspectable, not absent.

## Status

**0.1.0** — the core runtime is ported from activegraph with red-green
TDD: event log, projection + query API, GraphStore (in-memory + SQLite,
both conformance-verified), Cypher patterns, the Runtime/LogAgent with
routing, budget, approvals, authority, run quanta, frames, packs, sinks,
the LLM replay cache, tools, the trace printer, and the CLI. Built on
[crig](https://github.com/dsisnero/crig) 0.39.1 via its hook system.
Deferred items (marked `[-]` in `plans/parity.md`): Postgres/FalkorDB
backends, sandbox executor, pack manifest/loader, CLI quickstart, and the
fact-driven parity completion gate.

## License

Chronicle is licensed under the MIT License. See [LICENSE](LICENSE).

## Contributing

See [docs/pr-workflow.md](docs/pr-workflow.md). Tests must remain
deterministic — no live network calls in CI; model and tool tests use
recorded fixtures and mocks.
