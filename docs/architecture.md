# Architecture

Chronicle is a log-primary, Sans-IO agent runtime in Crystal. The append-only
event log is the source of truth; the working graph is a deterministic
projection of it. The core never opens sockets, reads the clock directly for
decisions, or runs shell commands — time, randomness, and I/O are injected or
recorded at the boundary.

## Layers

```text
Crystal platform edge (sockets, fibers, filesystem, provider/tool adapters)
  ↕ bytes / effect results
Sans-IO adapters (incremental parsing and serialization; no sockets)
  ↕ typed ingress events / effect requests
Log-primary core (event store, projection, router, behaviors, runner)
```

- **Platform edge** — provider executors, `ModelEffectWorker`, CLI I/O,
  session stores. It turns every observed result into an event.
- **Sans-IO** — the HTTP/1 framing state machine (`src/chronicle/sans_io/http.cr`)
  and the event-log codec: pure parsers/serializers with retained state, no
  sockets.
- **Log-primary core** — `EventLog`/`EventStore`, `GraphProjection` behind a
  `GraphStore`, `Chronicle.parse`/`PatternMatcher`, `Runtime`/`LogAgent`,
  router, caches, sinks, packs, frames, and trace.

Only routing must be deterministic. The rest follows activegraph semantics;
divergences are recorded in `plans/parity.md`.

## Module map (`src/chronicle/`)

- **Log & persistence** — `event.cr`, `event_log.cr`, `event_log_codec.cr`,
  `event_store.cr`, `memory_event_store`/`sqlite_event_store`,
  `store_url.cr`, `session_store.cr`.
- **Graph** — `graph_projection.cr` (projection + write/emit + query API +
  patches + views), `graph_store.cr` (backend seam), `sqlite_graph_store.cr`,
  `patterns.cr` (Cypher subset), `ids.cr`, `json_compare.cr`,
  `json_converters.cr`.
- **Runtime** — `runtime.cr` (routing, budget, approvals, authority, run
  modes, frames, packs, trace/status), `log_agent.cr`, `agent_hook.cr`,
  `behavior_runner.cr`, `replay.cr`, `model_executor.cr`,
  `provider_catalog.cr`.
- **Caches** — `llm_cache.cr`, `tool_cache.cr`, `effect_artifact.cr`,
  `content_hash.cr`.
- **Tools & effects** — `tool.cr`, `tool_cache.cr`, `tool_permission.cr`,
  `effect.cr`, `approval.cr`.
- **Observability** — `sink.cr` (Sans-IO outbound observers), `trace.cr`
  (causal chains), `telemetry.cr`, `diff_formatter.cr`.
- **Edge/CLI** — `platform_edge.cr`, `channel.cr`, `config.cr`,
  `routing_config.cr`, `cli.cr`, `tui.cr`, `session_store.cr`.

## Key invariants

- The log is append-only and authoritative; replaying it reproduces the
  projection and routing decisions without model/tool/network calls.
- The `GraphProjection` writes through its `GraphStore` in place; any backend
  passing the `GraphStoreConformance` suite is interchangeable.
- The `EventStore` is durable history; the `GraphStore` is a recoverable
  projection (losing one is recoverable by replay, losing the other is not).
- Providers/credentials never enter the event log; only normalized effect
  requests and results do.
