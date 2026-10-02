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
  `event_store.cr` (`MemoryEventStore`), `sqlite_event_store.cr`,
  `postgres_event_store.cr`, `store_url.cr`, `session_store.cr`,
  `retention.cr`, `migration.cr`.
- **Graph** — `graph_projection.cr` (projection + `emit` + query API +
  patches + views), `graph_store.cr` (backend seam),
  `sqlite_graph_store.cr`, `postgres_graph_store.cr`,
  `falkordb_graph_store.cr`, `patterns.cr` (Cypher subset), `ids.cr`,
  `json_compare.cr`, `json_converters.cr`, `diff.cr`, `diff_formatter.cr`,
  `promote.cr`, `replay.cr`.
- **Runtime** — `runtime.cr` (routing, budget, approvals, authority, run
  modes, frames, packs, trace/status), `log_agent.cr`, `agent_hook.cr`,
  `behavior_runner.cr`, `model_executor.cr`, `provider_catalog.cr`,
  `routing.cr`, `routing_config.cr`, `budget.cr`, `approval.cr`,
  `authority.cr`, `dev_override.cr`, `status.cr`, `frame.cr`, `view.cr`.
- **Packs** — `packs.cr`, `pack.cr`, and `packs/*` (annotation DSL, loader,
  manifest, settings, discovery, scheduler, prompts, `diligence.cr`).
- **LLM, tools & effects** — `llm_types.cr`, `llm_recorded.cr`,
  `prompt.cr`, `structured_output.cr`, `native.cr`, `wire.cr`, `tool.cr`,
  `tool_recorded.cr`, `tool_permission.cr`, `effect.cr`, `effect_artifact.cr`.
- **Caches** — `llm_cache.cr`, `tool_cache.cr`, `embedding_cache.cr`,
  `embedding.cr`, `content_hash.cr`.
- **Observability** — `sink.cr`, `trace.cr`, `telemetry.cr`, `logging.cr`,
  `metrics.cr`, `prometheus.cr` (Sans-IO rendering), `prometheus_http.cr`
  (the optional HTTP scrape edge), `opentelemetry_metrics.cr`.
- **Edge & CLI** — `sandbox.cr` (isolated trial child), `platform_edge.cr`,
  `channel.cr`, `config.cr`, `cli.cr`, `cli_main.cr`, `tui.cr`,
  `quickstart.cr`, `sans_io/http.cr`.

## Key invariants

- The log is append-only and authoritative; replaying it reproduces the
  projection and routing decisions without model/tool/network calls.
- Every event — graph mutations *and* runtime lifecycle (`goal.created`,
  `behavior.*`, `llm.*`, `tool.*`, `authority.*`, `runtime.*`,
  `pack.loaded`) — is emitted through `GraphProjection#emit`, so
  `graph.events` is the complete per-run log (upstream parity).
- The event store stamps `sequence` on append; an emitter's provisional
  sequence is ignored (SQLite `AUTOINCREMENT` / Postgres `BIGSERIAL`
  semantics), so the log is strictly increasing and directly codable.
- The `GraphProjection` writes through its `GraphStore` in place; any backend
  passing the `GraphStoreConformance` suite is interchangeable.
- The `EventStore` is durable history; the `GraphStore` is a recoverable
  projection (losing one is recoverable by replay, losing the other is not).
- Providers/credentials never enter the event log; only normalized effect
  requests and results do.
