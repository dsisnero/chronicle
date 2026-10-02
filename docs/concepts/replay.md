# Replay

Replay is reconstructing graph state from the event log. The graph is a
projection of the log (see [`graph`](graph.md)); replay is the operation
that computes the projection. Every time you load a run from a store,
fork a run, or strict-check a run, replay is what runs underneath.

The framework guarantees that **replay is deterministic** given the
event log. Two replays of the same log produce byte-identical graph
state. That guarantee is the foundation for forking, strict-mode
validation, and the audit-trail contract.

## What replay does

Three operations trigger replay:

- **`Runtime.load(path, run_id, agent)`** — loads a persisted run.
  Replay reads every event from the store and rebuilds the in-memory
  graph state. (Divergence: upstream's `Runtime.load(url,
  llm_provider=...)` takes a provider; Chronicle takes an explicit
  `Crig::Agent(M)` because providers are wired through the Crig seam.)
- **`runtime.fork(at_event: ...)`** — creates a new run sharing the
  parent's events up to the fork point. Replay reconstructs the shared
  prefix in the fork; new behavior fires after the fork point execute
  fresh. See [`forking`](forking.md).
- **`GraphProjection.replay(events)`** (explicit) — rebuilds a
  projection from an event array without persisting or firing listeners.
  Used by tests, the CLI `replay` command, and migration scripts that
  need to verify replay determinism without going through a live store.

```crystal
graph = Chronicle::GraphProjection.replay(store.iter_events)
```

## The cache layer

For LLM and tool calls to replay deterministically, the framework caches
their responses by content hash:

- **LLM responses** (`Chronicle::LLMCache`) are keyed on the prompt's
  full content hash (system message + user messages + model + tool
  definitions + output schema). Replay reads `llm.responded` events from
  the log, indexes them by their corresponding `llm.requested`'s prompt
  hash, and returns the cached response when a behavior re-fires with
  the same prompt.
- **Tool responses** (`Chronicle::ToolCache`) are keyed on the tool's
  name plus a deterministic hash of its arguments. Same mechanism —
  replay reads `tool.responded` events and serves them to re-firing
  behaviors.
- **Embedding responses** (`Chronicle::EmbeddingCache`) are keyed on a
  content hash of the input texts plus model, and are recorded as
  `embedding.requested` / `embedding.responded` pairs. `Runtime#embed` /
  `ctx.embed` record and replay through this cache.

The cache makes replay cheap: no LLM calls, no tool execution, just
event-log reads. The cost is the disk space for the responses in the
store, which is bounded by the run's size.

## Strict mode vs permissive mode

Replay runs in one of two modes via `Chronicle::ReplayEngine`:

- **Permissive replay** (`ReplayMode::Permissive`) — events are
  re-emitted from the log; the runtime trusts the recording. The cache
  serves responses for any behavior whose prompt hash matches a recorded
  one. Behaviors whose hash doesn't match get fresh calls (with the
  caveat that those calls land as new events in the new run's log, not
  the parent's).
- **Strict replay** (`ReplayMode::Strict`) — behaviors re-fire against
  the recorded seed and the framework compares the live event stream
  against the recorded one. Any drift raises
  `ReplayDivergenceError` pinned to the first divergent event id.
  Lifecycle events (`behavior.*`, `runtime.*`, `context.read`),
  non-replayable failed LLM attempt pairs, and operator-invoked
  embedding pairs are excluded from the comparison.

```crystal
result = Chronicle::ReplayEngine.new.replay(
  recorded_events,
  Chronicle::ReplayMode::Strict,
  emitted_events: live_events,
)
```

Strict mode is for verifying that the run is replayable — a green strict
replay proves the run is reproducible. Permissive mode is for
development workflows where behaviors are still being edited and
divergence is expected. `Runtime.load` reconstructs permissively; the
fork primitive replays its shared prefix, and `fork(replay_llm_cache:
true, replay_tool_cache: true)` serves the prefix from the parent's
recorded responses.

## The determinism contract

Replay determinism rests on the [`behaviors`](behaviors.md) determinism
contract: same event, same graph state, same view → same mutations.
Three rules from that contract that replay specifically depends on:

- **No `Random`, `Time.utc`, or `Random::Secure.uuid` in behavior
  bodies.** If the body needs these, get them from the event (which
  carries the recorded timestamp) or from the runtime's deterministic id
  generator (`graph.ids`).
- **No I/O outside the framework's primitives.** Direct
  `HTTP::Client.get` in a behavior body breaks replay — the response
  isn't in the cache.
- **No mutable global state across behavior fires.** A counter in a
  module-level variable that increments per fire would diverge under
  replay.

The framework doesn't statically enforce these rules. A behavior that
breaks them runs fine on first execution; replay or fork discovers the
violation as `ReplayDivergenceError`.

## When replay is invoked

The triggers, restated for reference:

- **Store load** — every `Runtime.load(path, run_id, agent)` runs replay
  during construction. The graph state is rebuilt from the event log
  before any new work happens.
- **Fork** — `runtime.fork(at_event: ...)` runs replay up to the fork
  point in the new run, then resumes live execution from there.
- **Explicit replay** — `GraphProjection.replay(events)` rebuilds graph
  state from an event log. Uncommon outside of tests, the `replay` CLI
  command, and migration code.

## What's related

- [`graph`](graph.md) — the projection replay computes. Owns the "graph
  as projection of event log" principle.
- [`events`](events.md) — the append-only history replay reads.
- [`behaviors`](behaviors.md) — the determinism contract that makes
  replay work.
- [`forking`](forking.md) — the operation that runs replay up to the
  fork point.
- [`failure-model`](failure-model.md) — events vs exceptions; why
  divergence is an exception rather than a silent event.
