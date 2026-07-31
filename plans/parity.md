# ActiveGraph Parity Plan

Port core primitives and design patterns from
[yoheinakajima/activegraph](https://github.com/yoheinakajima/activegraph) —
the reference implementation of the event-sourced, reactive-graph design
described in [The Log is the Agent](https://arxiv.org/html/2605.21997v1).

## Source of Truth

- **Upstream**: https://github.com/yoheinakajima/activegraph (Python)
- **Pinned revision**: `8aedb1866cf5dce056af97529152ffd6f468a1ed`
  (checkout at `vendor/activegraph/`)
- **Design reference**: arXiv paper 2605.21997v1
- **DeepWiki**: https://deepwiki.com/yoheinakajima/activegraph

Before implementing any core logic change, consult activegraph's DeepWiki for
context, then validate against the pinned source. DeepWiki is guidance, not the
source of truth (its GraphStore description is stale). Record any divergence
from activegraph's design in the Intentional Divergence section.

## Status Legend

- `[x]` done (specs green)
- `[ ]` pending work
- `[-]` intentionally deferred / out of scope

## Parity tooling

The [cross-language-crystal-parity] skill is grammar-driven: any language with
an available tree-sitter grammar (bundled `chiasmus-discover`, `CHIASMUS_GRAMMAR_DIR`,
or repo-local `./grammars`) works without editing the skill. Generated manifests
live in `plans/inventory/python_*_parity.tsv`; the curated ledger is
`plans/inventory/python_port_inventory.tsv`.

```bash
SKILL=/Users/dominic/.agents/skills/cross-language-crystal-parity
"${SKILL}/scripts/ensure_parity_plan.sh" . vendor/activegraph/activegraph python auto 0
"${SKILL}/scripts/check_port_inventory.sh" . plans/inventory/python_port_inventory.tsv vendor/activegraph/activegraph python
"${SKILL}/scripts/check_source_parity.sh" . plans/inventory/python_source_parity.tsv vendor/activegraph/activegraph python
"${SKILL}/scripts/check_test_parity.sh" . plans/inventory/python_test_parity.tsv vendor/activegraph/activegraph python
```

Current state: `check_source_parity` (1210 symbols) and `check_test_parity`
(42 tests) pass. `check_port_inventory` lists ~1170 untracked symbols — the
ledger is curated, so expand it per phase below. `plan_with_chiasmus.sh` and
`check_completion_gate.sh` need `chiasmus-plan`/`chiasmus-complete`, which are
not released yet — treat their absence as a tooling gap, not a porting signal.

[cross-language-crystal-parity]: /Users/dominic/.agents/skills/cross-language-crystal-parity/SKILL.md

---

## Phase 0 — Foundations (done)

The event-sourcing core, graph projection, graph-store seam, and Cypher
pattern layer are ported and green.

- [x] Event envelope — `Clarity::Event` (schema_version, sequence, id, type,
      actor, caused_by, timestamp, canonical_json) — `spec/clarity/event_spec.cr`
- [x] Append-only log — `Clarity::EventLog` (append, fork_at, events) —
      `spec/clarity/event_log_spec.cr`
- [x] Log codec — `Clarity::EventLogCodec` (JSON::Serializable decode, byte-stable)
      — `spec/clarity/event_log_spec.cr`
- [x] EventStore interface + backends — `Clarity::EventStore`, `MemoryEventStore`,
      `SQLiteEventStore` (append/iter_events/get_event/count/truncate_after/close)
      — `spec/clarity/event_store_spec.cr`, `sqlite_event_store_spec.cr`
- [x] Replay — `Clarity::ReplayEngine` (strict/permissive) — `spec/clarity/replay_spec.cr`
- [x] Projection — `Clarity::GraphProjection` (apply, diff) — `spec/clarity/graph_projection_spec.cr`
- [x] Graph query API — `objects(type:, where:)`, `query`, `relations`,
      `get_relations`, `objects_in_types`, `has_object_of_type`, `neighborhood`
      — `spec/clarity/graph_query_spec.cr`
- [x] Entities — `GraphObject` (id, type, JSON-string data, version, provenance),
      `GraphRelation`, `Provenance` — `spec/clarity/graph_projection_spec.cr`
- [x] Patches — `Patch`/`PatchState` + `propose_patch`/`apply_patch`/`reject_patch`/
      `patch_object`; `patch.*` events folded by `apply` — `spec/clarity/patch_spec.cr`
- [x] Views — `Clarity::View`/`ViewSpec` + `GraphProjection#build_view` — `spec/clarity/view_spec.cr`
- [x] GraphStore backend — `Clarity::GraphStore` (abstract put/get/remove/all ×
      objects/relations/patches, query hooks, lifecycle) + `InMemoryGraphStore` —
      `spec/clarity/graph_store_spec.cr`
- [x] Store conformance — reusable `spec/clarity/graph_store_conformance.cr` mixin —
      `spec/clarity/graph_store_spec.cr`
- [x] Chain matching — `Clarity::ChainMatch` + `GraphStore#match_chain`
      (homomorphic DFS walk) — `spec/clarity/graph_store_conformance.cr`
- [x] IDs — `Clarity::IDGen` (global object counter `task#1, task#2, claim#3`,
      `evt_`/`rel_`/`patch_`/`frame_`, `run`/ULID, `reseed_from_events`) — `spec/clarity/ids_spec.cr`
- [x] Clock — `Clarity::Clock` + `WallClock`/`FrozenClock`/`TickingClock` — `spec/clarity/clock_spec.cr`
- [x] Cypher subset — `Clarity.parse`/`Pattern`/`PatternMatcher`/
      `UnsupportedPatternError` — `spec/clarity/patterns_parser_spec.cr`, `patterns_matcher_spec.cr`
- [x] JSON comparison — `Clarity::JsonCompare` (numeric-aware equality, ordered
      comparisons, `in?`, data parsing) — shared by matcher + where predicate
- [x] Frame value type — `Clarity::Frame` + `FrameStack` — `spec/clarity/frame_spec.cr`
- [x] Behaviors — `Clarity::BehaviorRunner` (subscription, priority, fan-out) — `spec/clarity/behavior_runner_spec.cr`
- [x] Session store, telemetry, effect artifacts, tool cache/permissions, approval,
      content hashing — `spec/clarity/*_spec.cr`

## Phase 1 — Graph write/emit surface (top structural drift)

The single largest drift finding: `activegraph.core.graph.Graph` maps to
`Clarity::GraphProjection`, but the Crystal side has only the read surface.
Upstream `Graph` is the write facade that owns the log + projection + store and
emits events; Clarity currently builds projections by folding events manually.
From `plans/generated/parity/python/parity.tsv`:

- [x] `add_object(type, data, actor:)` — builds `object.created` event, stamps
      provenance, emits — `core/graph.py:add_object`
- [x] `add_relation(source, target, type, data, actor:)` — `core/graph.py:add_relation`
- [x] `remove_object` / `remove_relation` (relation cascade on object removal) —
      `core/graph.py:remove_object`
- [x] `emit(event)` mutator + `events` accessor + `attach_store` (durability sink)
      — `core/graph.py:emit`, `attach_store`
- [x] Listener API — `add_listener`/`remove_listener` (runtime hooks) — `core/graph.py`
- [-] Sinks — `add_sink`/`remove_sink`/`flush_sinks`/`sink_statuses` (bounded
      outbound observers) — `core/graph.py`, `sinks/*` — deferred to Phase 6
- [x] `replay_event`/`replayed_ids` (silent replay reconstruction) — `core/graph.py`
      (replay path exists via `ReplayEngine`; `replayed_ids` tracking is N/A)
- [x] JSON serialization on `GraphObject`/`GraphRelation` via `JSON::Serializable`
      (data blob uses shared `Clarity::RawJSON` converter) — `core/graph.py`
- [x] Provenance stamping invariant: behaviors may not inject `provenance` via
      data (raise `Clarity::ReservedFieldError`) — `core/graph.py`

## Phase 2 — Persistence backends

- [x] `Clarity::EventStore` interface + `MemoryEventStore` + `SQLiteEventStore`
      (append/iter_events/get_event/count/truncate_after/close); appends reject
      duplicate ids with `DuplicateEventError`
- [x] EventStore conformance suite (mirror `store/conformance.py`) run against
      Memory + SQLite backends — `spec/clarity/event_store_conformance.cr`
- [x] Store URL parsing — `Clarity.parse_store_url`/`StoreURL`/`InvalidStoreURL`
      (sqlite:///, sqlite:////, postgres://, postgresql://) — `spec/clarity/store_url_spec.cr`
- [-] Postgres event store — deferred (needs `pg` shard + live server; the
      `EventStore` protocol is the path for adding it)
- [-] Retention/compaction (`store/retention.py`) — deferred: offline snapshot +
      archive-tier compaction depends on a snapshot sidecar and `causal_chain`,
      both not yet ported
- [ ] `EventLog` gains `count`/`get_event`/`iter_events` conveniences if needed

## Phase 3 — Runtime execution surface

`activegraph.runtime.runtime.Runtime` maps to `Clarity::LogAgent`; the drift
list shows the Crystal side is missing most of the run loop and effect emission.
From `parity.tsv` (`missing_contains` on Runtime):

- [x] Bounded run modes — `run_quantum(prompt, steps)` / `run_until_idle(prompt)`
      via a step-capped `drive_loop` — `runtime/runtime.py` — `spec/clarity/runtime_phase3_spec.cr`
- [x] Budget — `budget_remaining` / `start_budget` — `runtime/budget.py`
- [x] Tool lookup — `get_tool(name)` — `spec/clarity/runtime_phase3_spec.cr`
- [x] Approvals — `pending_approvals` / `approve` / `add_pending_approval` —
      `runtime/runtime.py` — `spec/clarity/runtime_phase3_spec.cr`
- [x] Authority — `authority_ceiling` / `set_authority_ceiling` /
      `evaluate_capability_authority` (read < write < admin < root) —
      `runtime/authority.py` — `spec/clarity/runtime_phase3_spec.cr`
- [x] Trace/status output — `export_trace` (structured event JSON) / `status`
      — `runtime/runtime.py`, `trace/*` — `spec/clarity/runtime_phase3_spec.cr`
- [x] Structured effect events — `llm.requested/responded/failed`,
      `tool.requested/responded` recorded around invocation (via `Clarity::AgentHook`
      for the runner path and `Runtime` for the manual path)
- [ ] Run loop — `run_goal`/`run_until`/`run_quantum`/`run_until_idle` full parity —
      `run_quantum`/`run_until_idle` done; `run_goal` naming deferred
- [ ] `get_behavior` / view injection into behavior context — deferred
- [ ] Packs — `load_pack` / `loaded_packs` / `pack_settings_for_behavior` —
      deferred (Phase 7)
- [ ] Promote — `promote` / `rebuild_shorts` — deferred
- [ ] Fork at runtime — `fork` / `save_state` — deferred (Phase 9 / fork path)
- [ ] Schedule — `schedule` / `fire_due_delayed` / `loop` — deferred
- [ ] Dev override — `dev_override` / `dev_overrides` / `validate_dev_override` — deferred
- [ ] Registry — `ensure_registry` / behavior registration wiring — deferred

## Phase 4 — LLM layer + replay cache

- [x] Content-addressed store — `Clarity::EffectArtifactStore`/`LLMCache` base
      — `spec/clarity/effect_artifact_spec.cr`, `llm_cache_spec.cr`
- [x] Wire the LLM cache into replay/fork: `LLMCache.from_events` harvests
      `llm.responded` (via `caused_by` → `llm.requested` request_hash), skips
      error-shaped attempts, and `Runtime.load(replay_llm_cache: true)`
      pre-populates it. `Runtime` consults the cache before any provider call
      and serves hits with `cache_hit: true` recorded; provider successes are
      recorded back into the cache. `replay_strict: true` raises
      `ReplayDivergenceError` on prompt-hash mismatch — `llm/cache.py`,
      `runtime.py` — `spec/clarity/llm_cache_wiring_spec.cr`
- [-] Provider adapters (Anthropic/OpenAI/native structured output) — deferred;
      `Clarity::ModelExecutor` already routes through registered executors —
      `llm/anthropic.py`, `llm/openai.py`, `llm/native.py`
- [-] Wire protocol (request/response types, canonical serialization,
      `prompt_hash`) — deferred; the effect/llm event model already carries
      `request_hash` — `llm/wire.py`, `llm/types.py`, `llm/prompt.py`, `llm/parsing.py`
- [-] Embedding — deferred — `llm/embedding.py`, `llm/embedding_cache.py`

## Phase 5 — Tools

- [x] Tool base + registry — `Clarity::Tool` (name, description, callable),
      `Clarity::ToolRegistry` (@tool-style snapshot/clear) — `tools/base.py`,
      `tools/decorators.py` — `spec/clarity/tools_spec.cr`
- [x] `graph_query` tool — `Clarity.make_graph_query_tool(graph)` bound to a
      `GraphProjection`, returns object refs with limit/truncated —
      `tools/graph_query.py` — `spec/clarity/tools_spec.cr`
- [x] Wire tools through the runtime — `Runtime` accepts `tools`; `drive_model`
      passes tool names as `allowed_tools`; `drive_tools` invokes tools by name,
      records `tool.requested`/`tool.responded`, and serves `ToolCache` hits;
      `Runtime.load(replay_tool_cache: true)` pre-populates the cache —
      `tools/cache.py` — `spec/clarity/tools_spec.cr`
- [-] `web_fetch` tool — deferred (external HTTP at the platform edge) —
      `tools/web_fetch.py`
- [x] Tool result caching via the existing `Clarity::ToolCache` (recorded replay)

## Phase 6 — Sinks + observability

- [x] Sink base + bounded FIFO + overflow policy — `Clarity::Sink`, `SinkHandle`,
      `OverflowPolicy` (drop_newest/drop_oldest/fail_sink), `SinkState`,
      `DeliveryContext`, `SinkStatus` — `sinks/base.py` — `spec/clarity/sinks_spec.cr`
- [x] Graph sink surface (completes Phase 1) — `GraphProjection#add_sink`/
      `remove_sink`/`flush_sinks`/`sink_statuses`; `emit` offers to sinks before
      listeners — `sinks/dispatch.py`
- [x] Testing sink + JSONL sink — `Clarity::TestingSink`, `Clarity::JSONLSink` —
      `sinks/testing.py`, `sinks/jsonl.py` — `spec/clarity/sinks_spec.cr`
- [x] Sink conformance cases (order, unicode round-trip, bounded overflow,
      status, remove) — `spec/clarity/sinks_spec.cr`
- [-] Observability dashboards (metrics, status, logging, prometheus, otel) —
      deferred — `observability/*`
- [-] Sink conformance as a reusable mixin — deferred (covered inline in sinks_spec)

## Phase 7 — Packs + policy

- [x] Pack bundle — `Clarity::Pack` (name/version validation, object_types,
      relation_types, tools, policies) — `packs/__init__.py` — `spec/clarity/packs_spec.cr`
- [x] Per-behavior policy — `Clarity::Policy` (can_create, can_create_relation,
      can_call_tool, requires_approval) — `policy.py`
- [x] Runtime load — `Runtime#load_pack` (registers pack tools, records
      `pack.loaded`, `loaded_packs`) — `runtime/runtime.py`
- [x] Policy approval routing — `tool_requires_approval?`; `invoke_tool` queues
      a pending approval instead of executing — `spec/clarity/packs_spec.cr`
- [-] Pack manifest/loader/scaffold (TOML, content hashing, `verify_surface`) —
      deferred — `packs/manifest.py`, `packs/loader.py`, `packs/scaffold.py`
- [-] Diligence pack — deferred — `packs/diligence/*`
- [-] Registration validation suite — deferred (reserved-field rejection already
      lands in Phase 1) — `runtime/registration_errors.py`, `runtime/config_errors.py`

## Phase 8 — Frames wiring

- [x] `Clarity::Frame` value + `FrameStack` — `spec/clarity/frame_spec.cr`
- [ ] `frame_id : String?` on `Clarity::Event` envelope
- [ ] Runtime `push_frame`/`pop_frame` lifecycle — `frame.py`
- [ ] Group events by `frame_id` in log inspect + trace export

## Phase 9 — Sandbox + CLI + trace printer

- [ ] Sandbox executor/conformance (`_child`, `executor`, `conformance`) — `sandbox/*`
- [ ] CLI quickstart/renderers — `cli/quickstart.py`, `cli/renderers.py`
- [ ] Trace printer/causal rendering — `trace/printer.py`, `trace/causal.py`

## Phase 10 — External GraphStore backends (stretch)

- [ ] SQLite-backed `GraphStore` (query-hook pushdown) — the conformance suite is
      ready; any backend passing it is interchangeable
- [ ] Postgres / FalkorDB GraphStore pushdown — `store/postgres.py`, `store/falkordb.py`
- [ ] `graph_store=` injection seam (analogous to upstream constructor param)

---

## Intentional Divergence

- **Ordered comparisons on incomparable types:** matching activegraph, ordered
  comparisons (`<`, `>`, `<=`, `>=`) raise on mixed/incomparable non-nil values.
  Clarity raises `Clarity::PatternTypeError` (analogous to Python's `TypeError`).
  Nil operands still evaluate to no-match. Residual: Python compares arrays
  lexicographically; Clarity raises for array operands. Equality ops use
  numeric-aware comparison (`3 == 3.0` is true).
- **`objects(where:)` ordered ops guard both operands.** Upstream guards only
  `a` (`a is not None and a > b`); Clarity returns no-match for any nil operand,
  consistent with the pattern matcher.
- **JSON storage shape:** upstream `Object.data` is a Python dict; Clarity stores
  it as a canonical JSON `String`. WHERE/path semantics are identical.
- **Time/randomness allowed in the core.** Only routing must be deterministic.
  `IDGen#run`/ULID uses wall clock + `Random::Secure`; the core I/O-safety gate
  forbids only direct I/O, environment access, and process capabilities (Sans-IO).
- **Projection writes through its GraphStore in place**, mirroring upstream
  `Graph._state` mutation; replay builds a fresh projection.

## Acceptance Gates

- [ ] Same event log → same projection and routing decisions on replay
- [ ] Any GraphStore backend passes the full `GraphStoreConformance` suite
- [ ] `GraphProjection` write/emit surface matches upstream `Graph`
      (add/remove/attach_store/listeners/sinks)
- [ ] `LogAgent` run loop (`run_goal`/`invoke_*`) emits causally-linked
      `llm.*`/`pattern.*`/`tool.*` events with provenance
- [ ] LLM cache serves recorded responses on matching hashes during replay/fork;
      strict mismatch raises `ReplayDivergenceError`
- [ ] `frame_id` preserved on events and visible in log inspect
- [ ] `check_source_parity.sh` and `check_test_parity.sh` pass; `check_port_inventory.sh`
      reports no untracked symbols once the ledger is expanded
