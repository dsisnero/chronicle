# Changelog

All notable changes to this project are documented in this file.

## [0.1.0] — 2026-07-31

Crystal port of activegraph (the event-sourced reactive-graph agent
runtime) and rename from `clarity` to `chronicle`. Developed phase by
phase with red-green TDD; each phase gated by
`crystal tool format --check src spec`, `ameba src spec`, and `crystal spec`.

### Core log / graph

- `Chronicle::Event` — immutable envelope (schema_version, sequence, id,
  type, actor, caused_by, frame_id, timestamp, payload) with byte-stable
  canonical JSON and SHA-256 content hash.
- `Chronicle::EventLog` — append-only log enforcing sequence/causality
  invariants; `fork_at`; versioned newline-delimited `EventLogCodec`
  (JSON::Serializable decode, byte-stable round-trip).
- `Chronicle::EventStore` protocol with `MemoryEventStore` and
  `SQLiteEventStore` backends, pinned by a reusable conformance suite
  (duplicate-id rejection, cursor iteration, truncate, idempotent close).
- `Chronicle::GraphProjection` — objects + typed relations folded from
  events; query API (`objects(type:, where:)`, `relations`, `get_relations`,
  `objects_in_types`, `has_object_of_type`, `neighborhood`, `match_chain`),
  structural `diff`, and a write/emit surface (`add_object`, `add_relation`,
  `remove_*`, `emit`, listeners, sinks).
- `Chronicle::GraphStore` seam — `InMemoryGraphStore` and
  `SQLiteGraphStore`, both passing the shared `GraphStoreConformance` suite;
  the projection writes through its store in place.
- `Chronicle::Patch` — optimistic concurrency (`proposed → applied |
  rejected`) with `expected_version` checks, ported patch lifecycle.
- `Chronicle::View` / `ViewSpec` — scoped graph reads.
- `Chronicle::IDGen` — global monotonic object counter, `evt_/rel_/patch_/
  frame_` sequences, `run`/ULID, `reseed_from_events`.
- `Chronicle.parse` / `PatternMatcher` — the strict Cypher subset with
  `UnsupportedPatternError` (refused-feature and syntax-error factories)
  and a WHERE evaluator (equality + ordered comparisons + `NOT EXISTS`).

### Runtime / agent loop

- `Chronicle::Runtime` / `LogAgent` over crig 0.39.1, using the crig hook
  system (`Chronicle::AgentHook`) for `llm.requested` / `tool.requested` /
  `tool.responded` recording and `ToolCache` population.
- Deterministic router (`routing.decided` receipt, ordered fallback),
  budget (`budget_remaining`, `start_budget`), pending approvals and
  approval routing, authority ceiling, bounded run modes
  (`run_quantum`, `run_until_idle`), frames (`push_frame`/`pop_frame`),
  packs (`load_pack`, per-behavior `Policy`, policy-required tool routing),
  and structured output (`export_trace`, `status`, `Trace.causal_chain`,
  `chronicle-cli trace`).
- LLM replay cache — `LLMCache.from_events` harvests `llm.responded` by
  request hash; `Runtime.load(replay_llm_cache: true)` pre-populates it and
  serves hits without provider calls; `replay_strict` raises
  `ReplayDivergenceError` on prompt-hash mismatch.
- Tools — `Tool`/`ToolRegistry`, `make_graph_query_tool(graph)`, tool
  invocation with `tool.requested`/`tool.responded` events and `ToolCache`
  replay.
- Sans-IO sinks — `Sink`/`SinkHandle` with bounded FIFO + overflow policy
  and status; `TestingSink`, `JSONLSink`; `add_sink`/`flush_sinks`/
  `sink_statuses` on the projection.

### Integration

- Crig upgraded to 0.39.1: `Agent#build_completion_request`, `max_turns`
  default semantics, and the `AgentHook` recording surface.
- Store URL parsing (`Chronicle.parse_store_url` / `InvalidStoreURL`) for
  sqlite/postgres URL families.

### Chores

- Renamed the project from `clarity` to `chronicle` (namespace
  `Chronicle::`, shard targets `chronicle`/`chronicle-cli`,
  `src/chronicle/`, `spec/chronicle/`).
