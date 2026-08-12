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

- [x] Event envelope — `Chronicle::Event` (schema_version, sequence, id, type,
      actor, caused_by, timestamp, canonical_json) — `spec/chronicle/event_spec.cr`
- [x] Append-only log — `Chronicle::EventLog` (append, fork_at, events) —
      `spec/chronicle/event_log_spec.cr`
- [x] Log codec — `Chronicle::EventLogCodec` (JSON::Serializable decode, byte-stable)
      — `spec/chronicle/event_log_spec.cr`
- [x] EventStore interface + backends — `Chronicle::EventStore`, `MemoryEventStore`,
      `SQLiteEventStore` (append/iter_events/get_event/count/truncate_after/close)
      — `spec/chronicle/event_store_spec.cr`, `sqlite_event_store_spec.cr`
- [x] Replay — `Chronicle::ReplayEngine` (strict/permissive) — `spec/chronicle/replay_spec.cr`
- [x] Projection — `Chronicle::GraphProjection` (apply, diff) — `spec/chronicle/graph_projection_spec.cr`
- [x] Graph query API — `objects(type:, where:)`, `query`, `relations`,
      `get_relations`, `objects_in_types`, `has_object_of_type`, `neighborhood`
      — `spec/chronicle/graph_query_spec.cr`
- [x] Entities — `GraphObject` (id, type, JSON-string data, version, provenance),
      `GraphRelation`, `Provenance` — `spec/chronicle/graph_projection_spec.cr`
- [x] Patches — `Patch`/`PatchState` + `propose_patch`/`apply_patch`/`reject_patch`/
      `patch_object`; `patch.*` events folded by `apply` — `spec/chronicle/patch_spec.cr`
- [x] Views — `Chronicle::View`/`ViewSpec` + `GraphProjection#build_view` — `spec/chronicle/view_spec.cr`
- [x] GraphStore backend — `Chronicle::GraphStore` (abstract put/get/remove/all ×
      objects/relations/patches, query hooks, lifecycle) + `InMemoryGraphStore` —
      `spec/chronicle/graph_store_spec.cr`
- [x] Store conformance — reusable `spec/chronicle/graph_store_conformance.cr` mixin —
      `spec/chronicle/graph_store_spec.cr`
- [x] Chain matching — `Chronicle::ChainMatch` + `GraphStore#match_chain`
      (homomorphic DFS walk) — `spec/chronicle/graph_store_conformance.cr`
- [x] IDs — `Chronicle::IDGen` (global object counter `task#1, task#2, claim#3`,
      `evt_`/`rel_`/`patch_`/`frame_`, `run`/ULID, `reseed_from_events`) — `spec/chronicle/ids_spec.cr`
- [x] Clock — `Chronicle::Clock` + `WallClock`/`FrozenClock`/`TickingClock` — `spec/chronicle/clock_spec.cr`
- [x] Cypher subset — `Chronicle.parse`/`Pattern`/`PatternMatcher`/
      `UnsupportedPatternError` — `spec/chronicle/patterns_parser_spec.cr`, `patterns_matcher_spec.cr`
- [x] JSON comparison — `Chronicle::JsonCompare` (numeric-aware equality, ordered
      comparisons, `in?`, data parsing) — shared by matcher + where predicate
- [x] Frame value type — `Chronicle::Frame` + `FrameStack` — `spec/chronicle/frame_spec.cr`
- [x] Behaviors — `Chronicle::BehaviorRunner` (subscription, priority, fan-out) — `spec/chronicle/behavior_runner_spec.cr`
- [x] Session store, telemetry, effect artifacts, tool cache/permissions, approval,
      content hashing — `spec/chronicle/*_spec.cr`

## Phase 1 — Graph write/emit surface (top structural drift)

The single largest drift finding: `activegraph.core.graph.Graph` maps to
`Chronicle::GraphProjection`, but the Crystal side has only the read surface.
Upstream `Graph` is the write facade that owns the log + projection + store and
emits events; Chronicle currently builds projections by folding events manually.
From `plans/generated/parity/python/parity.tsv`:

- [x] `add_object(type, data, actor:)` — builds `object.created` event, stamps
      provenance, emits — `core/graph.py:add_object`
- [x] `add_relation(source, target, type, data, actor:)` — `core/graph.py:add_relation`
- [x] `remove_object` / `remove_relation` (relation cascade on object removal) —
      `core/graph.py:remove_object`
- [x] `emit(event)` mutator + `events` accessor + `attach_store` (durability sink)
      — `core/graph.py:emit`, `attach_store`
- [x] Listener API — `add_listener`/`remove_listener` (runtime hooks) — `core/graph.py`
- [x] Sinks — `add_sink`/`remove_sink`/`flush_sinks`/`sink_statuses` (bounded
      outbound observers) — `core/graph.py`, `sinks/*`. Sans-IO adaptation:
      emit enqueues into a bounded FIFO (overflow policies), flush drains it,
      per-sink exceptions are isolated into status/errors. Added `RaisingSink`
      and pinned the upstream conformance cases: raising-sibling isolation
      (a broken sink never suppresses a healthy sibling's deliveries/status)
      and replay-does-not-redeliver-history (GraphProjection.replay uses
      apply, never emit, so sinks never observe rebuilt history). Ported from
      activegraph sinks/conformance.py — `spec/chronicle/sinks_spec.cr`.
- [x] `replay_event`/`replayed_ids` (silent replay reconstruction) — `core/graph.py`
      (replay path exists via `ReplayEngine`; `replayed_ids` tracking is N/A)
- [x] JSON serialization on `GraphObject`/`GraphRelation` via `JSON::Serializable`
      (data blob uses shared `Chronicle::RawJSON` converter) — `core/graph.py`
- [x] Provenance stamping invariant: behaviors may not inject `provenance` via
      data (raise `Chronicle::ReservedFieldError`) — `core/graph.py`

## Phase 2 — Persistence backends

- [x] `Chronicle::EventStore` interface + `MemoryEventStore` + `SQLiteEventStore`
      (append/iter_events/get_event/count/truncate_after/close); appends reject
      duplicate ids with `DuplicateEventError`
- [x] EventStore conformance suite (mirror `store/conformance.py`) run against
      Memory + SQLite backends — `spec/chronicle/event_store_conformance.cr`
- [x] Store URL parsing — `Chronicle.parse_store_url`/`StoreURL`/`InvalidStoreURL`
      (sqlite:///, sqlite:////, postgres://, postgresql://) — `spec/chronicle/store_url_spec.cr`
- [-] Postgres event store — deferred (needs `pg` shard + live server; the
      `EventStore` protocol is the path for adding it)
- [-] Retention/compaction (`store/retention.py`) — deferred: offline snapshot +
      archive-tier compaction depends on a snapshot sidecar and `causal_chain`,
      both not yet ported
- [x] `EventLog` gains `count`/`get_event`/`iter_events`/`truncate_after`
      conveniences, mirroring the upstream `EventStore` protocol (append,
      iterate, count, lookup, truncate-after — CONTRACT v0.5 #2) on the
      in-memory append-only log. `truncate_after` drops every event after the
      given id and rewinds the sequence/causality bookkeeping.
      `spec/chronicle/event_log_spec.cr`.
- [x] Strict payload serde — `Chronicle::Serde` (CONTRACT v0.5 #4): JSON-only,
      human-inspectable, byte-stable. `encode_payload(JSON::Any)` /
      `decode_payload(String)` (decode-side corruption raises
      `CorruptedEventPayloadError` with a preview; long inputs truncated),
      `validate_event` as the fail-fast emit-time gate wired into
      `GraphProjection#emit` (only when a store is attached, mirroring upstream
      `core/graph.py:emit`), and `encode_event`/`decode_event` row marshalling
      through a `JSON::Serializable` `StoredEvent` record (payload embedded as
      a raw canonical JSON string via the `RawJSON` converter so the row never
      re-parses it — byte-exact round-trip). Error taxonomy:
      `StorageError` base with `NonSerializableEventError` (encode-side) and
      `CorruptedEventPayloadError` (decode-side) leaves. Divergence: upstream's
      encode-side strictness (Decimal/datetime/set coercion + runtime
      `_find_non_serializable` walker) is a compile-time guarantee in Crystal —
      `JSON::Any`/`String` payloads are JSON by construction, so
      `NonSerializableEventError` is the gate surface, not a commonly-reached
      runtime error. Ported from activegraph store/serde.py + store/errors.py +
      test_serde.py — `spec/chronicle/serde_spec.cr`.

## Phase 3 — Runtime execution surface

`activegraph.runtime.runtime.Runtime` maps to `Chronicle::LogAgent`; the drift
list shows the Crystal side is missing most of the run loop and effect emission.
From `parity.tsv` (`missing_contains` on Runtime):

- [x] Bounded run modes — `run_quantum(prompt, steps)` / `run_until_idle(prompt)`
      via a step-capped `drive_loop` — `runtime/runtime.py` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Budget — `budget_remaining` / `start_budget` — `runtime/budget.py`
- [x] Tool lookup — `get_tool(name)` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Approvals — `pending_approvals` / `approve` / `add_pending_approval` —
      `runtime/runtime.py` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Authority — `authority_ceiling` / `set_authority_ceiling` /
      `evaluate_capability_authority` (read < write < admin < root) —
      `runtime/authority.py` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Trace/status output — `export_trace` (structured event JSON) / `status`
      — `runtime/runtime.py`, `trace/*` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Structured effect events — `llm.requested/responded/failed`,
      `tool.requested/responded` recorded around invocation (via `Chronicle::AgentHook`
      for the runner path and `Runtime` for the manual path)
- [x] Run loop — `run_goal`/`run_until`/`run_quantum`/`run_until_idle` —
      `run_goal(goal, actor:)` emits `goal.created` and drains pack behaviors;
      `run_until(predicate)` drains until the predicate over the graph is
      satisfied, the log quiesces, or the budget stops the loop; the no-prompt
      `run_until_idle` emits a `runtime.idle` /
      `runtime.budget_exhausted` marker; the dispatch loop respects the event
      budget — `runtime/runtime.py` — `spec/chronicle/run_goal_spec.cr`,
      `spec/chronicle/run_until_spec.cr`
- [x] `get_behavior` — canonical lookup, unambiguous short-name resolution,
      `AmbiguousBehaviorError` on ambiguity (fully-qualified names still work)
      — `runtime/runtime.py`, `registration_errors.py` —
      `spec/chronicle/packs_dsl_spec.cr`, `spec/chronicle/runtime_phase3_spec.cr`
      (note: upstream has no separate "view injection into behavior context"
      feature; behaviors receive the attached graph directly)
- [x] `disable_pack` — `Runtime#disable_pack(name)` deregisters a loaded pack
      (CONTRACT v1.4 #3): behaviors stop firing NOW, tools stop resolving,
      typed-object schemas / relation specs revert to untyped (graph validators
      reinstalled), gating policies pruned from `gated_object_types`,
      pack-created state untouched. Registry maps (behavior/tool/object_type/
      relation_type/policy owners, object_type_schemas, relation_type_specs,
      loaded_packs, pack_settings) are pruned; `_pack_behaviors`/`_pack_tools`
      are filtered; short-name maps are rebuilt via `rebuild_shorts` (removal
      RESOLVES a previously-AMBIGUOUS short name to the surviving pack — e.g.
      `alpha.worker`+`beta.worker` → disable alpha → `worker` → `beta.worker`).
      Emits `pack.disabled` (name, version, behaviors, tools, object_types,
      relation_types). Idempotent (second disable → false, no event); unknown
      pack → `PackNotFoundError`; re-load = `load_pack` clears the disabled
      flag and returns true (fresh load, not idempotent skip). Ported from
      activegraph.test_disable_pack — `spec/chronicle/disable_pack_spec.cr`.
- [x] Packs — `load_pack` / `loaded_packs` / `pack_settings(pack_name)` /
      `get_behavior` / `get_tool` / `disable_pack` / `loaded_packs`.
      `Runtime#pack_settings` is the Form 3 cross-pack lookup (CONTRACT v0.9
      #7): canonical settings for any loaded pack by name, nil if not loaded,
      nil after disable — upstream's `_pack_settings_for_behavior` is a private
      helper whose lookup Chronicle's dispatch inlines. Ported from
      activegraph.runtime.runtime.Runtime#pack_settings —
      `spec/chronicle/pack_settings_spec.cr`.
- [x] Promote — `Runtime#promote(fork, dry_run:)` applies a fork's net
      structural delta to its parent (CONTRACT v1.3 #4). Three-way
      base/parent/fork comparison (`Promote.compute_promote_plan` rebuilds the
      parent's state at the fork point), producing creates/patches/removes for
      objects and relations. Both-sides changes conflict fail-closed and
      atomically (`PromoteConflictError` with `kind` in
      both_changed/dangling_relation/orphaning_removal, incl. same-id
      both-created collisions, identical concurrent edits, remove/modify
      pairs, referential-integrity checks); `dry_run` returns an advisory
      `PromotePlan` (is_promotable/is_empty/computed_against) without
      mutating; apply is quiescent — delta events persist/project but never
      fire behaviors (dispatch skips `promote:` actors), and the single
      reaction point is the `promote.applied` marker (actor "runtime") emitted
      first with every delta event `caused_by` it. Requires both runtimes on
      the same SQLite store and a direct-fork lineage (`PromoteLineageError`
      on reversed/grandchild/cross-store; `IncompatibleRuntimeState` on
      non-SQLite). `promote_warnings` surfaces fork-only pack loads and
      `pack.settings_overridden` (positional fork-tail detection). Promoted
      ids keep their fork-minted ids; parent id counters reseed past them.
      Additional CONTRACT v1.3 #4 semantics ported from test_promote —
      `spec/chronicle/promote_quiescence_spec.cr`: fork cannot slice a promote
      block (`Runtime#fork` raises `IncompatibleRuntimeState` when the cutoff
      sits at the marker or mid-delta; block fully included/excluded is fine);
      quiescent apply verified (delta events never fire behaviors — dispatch
      skips `promote:` actors; only the `promote.applied` marker reacts once,
      seeing post-promote state); load does not requeue delta events; both
      removed / same-id both created conflict as `both_changed`; unrelated
      same-store and cross-store runs rejected as `PromoteLineageError`;
      fork-of-fork promotes one level at a time; cascade removals promote
      cleanly; residue policy (fork tail removals of fork-created entities read
      base-None/fork-None and vanish from the delta and marker payload);
      settings-override warnings; pre-mutation schema validation
      (`validate_promote_schema` runs the parent graph's pack object/relation
      validators — canonicalizing valid typed data, raising `PackSchemaViolation`
      on violations, passing undeclared types through untyped). Forks own an
      independent pack-state snapshot (`PackRuntimeState#fork_snapshot`) so
      fork-side `load_pack` never leaks into the parent. Divergence: Chronicle's
      `patch_object`/`patch.applied` now honor upstream `update`-op field-merge
      semantics (op "replace" replaces); `Runtime#promote` emits "replace"
      patches of the fork's full object state. `Runtime#diff` and strict-replay
      promote-block exclusion remain separate deferred features.
      Ported from activegraph.test_promote — `spec/chronicle/promote_spec.cr`,
      `spec/chronicle/promote_quiescence_spec.cr`.
- [x] Diff — `Runtime#diff(other)` structural run comparison (CONTRACT v0.5
      #10). `Chronicle::Diff` (struct with `copy_with`), `DivergentObject` /
      `DivergentRelation` value structs with `summary`. Event partition: shared
      prefix matching by id+type+payload (a same-id-different-payload
      collision is NOT shared — CONTRACT #12), lifecycle events
      (`behavior.*`/`relation_behavior.*`/`runtime.*`; `promote.*` not
      filtered) excluded from the partition; divergent objects/relations via
      provenance-stripped snapshots compared per-id. `is_identical?` is the
      no-divergence check. The event partition reads the runs' append-only
      store logs (`store.iter_events`), not `graph.events` (which in Chronicle
      holds only graph-emitted events). `fork`/`load` now seed the dispatch
      cursor via `resume_from_idle` past the last `runtime.idle` (upstream
      `_requeue_unfired` high-water mark), so already-drained behaviors are not
      re-dispatched on reload. `behavior.started` is emitted for plain
      (non-LLM) behaviors too, so the `fired_on` set (event ids referenced by
      `behavior.started`) prevents a fork at a mid-run point from re-firing
      recorded behaviors.
      Ported from activegraph.test_diff — `spec/chronicle/diff_spec.cr`.
- [x] Promote — `rebuild_shorts` — folded into `Runtime#disable_pack`: the
      short-name maps are recomputed from the surviving canonical owners, so
      disabling one of two same-short-name packs resolves the AMBIGUOUS
      sentinel to the survivor (see the disable_pack row).
- [x] Fork at runtime — `Runtime#fork(at_event, label:)` copies the parent
      log up to and including `at_event` into a fresh SQLite `run_id`, records
      lineage (`runs` table via `SQLiteEventStore.fork_run`/`list_runs`/
      `upsert_run`: parent_run_id, forked_at_event_id, label), replays into a
      new graph, reseeds id counters (CONTRACT v0.5 #12), supports
      forks-of-forks, and refuses non-SQLite / unknown-event forks (raises
      `IncompatibleRuntimeState` / `EventNotFoundError`); the cut may not slice
      a promote block (CONTRACT v1.3 #4 — `reject_mid_promote_block_fork`;
      the underlying predicate is `RuntimeReason.promote_block?`, ported from
      `_is_promote_block`).
      WAL + synchronous=NORMAL on every connection; copied rows materialized
      before insert to dodge
      `database is locked`. Ported from test_fork / `SQLiteEventStore.fork_run` —
      `spec/chronicle/fork_spec.cr`. Divergence: `Runtime.load` takes a
      `Crig::Agent(M)`/`max_turns` (generic runtime); `save_state` still deferred.
- [x] Schedule — `activate_after` delayed-queue scheduling — a behavior with
      `activate_after=N` emits `behavior.scheduled` and fires N events later
      (where= re-checked at fire time, CONTRACT v0.7 #13); `parse_activate_after`
      accepts int / "N" / "N event" / "N events" and rejects bool, zero/negative,
      wall-clock units, and garbage — `runtime/runtime.py:_schedule/_fire_due_delayed`,
      `runtime/scheduler.py` — `spec/chronicle/activate_after_spec.cr`.
      Intentional divergence: Chronicle's dispatch tick is the event sequence
      (add_object emits events that advance it); `patch_object` does not emit a
      log event, so patches do not advance the schedule tick (upstream's
      object.updated does). The `schedule`/`loop` wall-clock extension is not
      ported.
- [x] Dev override — `dev_override` / `dev_overrides` / `validate_dev_override`
      (exact run-local receipts, promotion/event-log/R4 gates rejected before
      emission, receipts rebuilt from the log) — `runtime/dev_override.py` —
      `spec/chronicle/dev_override_spec.cr`
- [x] Registry — `Chronicle::Registry` matches events to behaviors (CONTRACT
      #10, registration order for ties): `all` / `index_of` / `match(event,
      graph)` returning (behavior, matching_relations, pattern_matches)
      triples. A behavior with both `on=[...]` and `pattern=` requires BOTH
      conditions; pattern-only (empty `on`) behaviors match every non-lifecycle
      event (behavior./relation_behavior./runtime./llm./tool./embedding./dev.
      suppressed); relation behaviors fire on ANY event whose payload
      references a candidate relation's source or target (`_matching_relations`
      walks the payload for string ids, `where=` re-checked). Runtime dispatch
      (`dispatch_new_events`) now uses the Registry, so relation behaviors fire
      on referencing events (not just relation.created) and pattern-only
      behaviors work. Removed the pre-port `PackBehavior#matches?` predicate
      the vendor does not have. Ported from activegraph.runtime.registry —
      `spec/chronicle/registry_spec.cr`.
- [x] Context-read tracing core — `Chronicle::ContextRead` (CONTRACT v1.10
      #1): `ReadRecorder` (ordered, deduplicated object-id read set for one
      behavior execution — first read wins the position, later reads are
      no-ops, replay-stable by construction), `TracedView` (wraps a
      `Chronicle::View`; `objects(type:)` records exactly the ids each call
      returns post-filter, while `relations`/`events` stay untraced), and
      `context_read_payload` (the batched `context.read` payload:
      `behavior`, `event_id`, `execution_event_id` — the `behavior.started`
      id — `object_ids` capped at `CONTEXT_READ_ID_CAP = 200`, `count` always
      exact,       `truncated: true` only when ids were dropped). Runtime wiring
      (CONTRACT v1.10 #1) is complete: `Runtime(trace_context_reads: true)`      threads a `ReadRecorder` through each behavior execution — `ctx.view`
      is a `TracedView` (records `objects(type:)` reads), `graph.get_object`
      point reads are recorded via a per-execution recorder seam on the
      projection (`context_read_recorder=`; internal writes like
      `add_object`'s return lookup bypass the traced accessor so writers are
      not recorded as readers), and ONE batched `context.read` is emitted at
      commit (right after the behavior's terminal lifecycle event;
      `execution_event_id` = the `behavior.started` id; read-free frames stay
      trace-free; opt-in, default off). `Chronicle::View` gained upstream's
      query methods (`objects(type:)`/`relations(type:)`/`events(type:)`).
      Divergence: Chronicle plain behaviors emit `behavior.started` (no
      `behavior.completed`), so the read commits after the last
      `behavior.*` lifecycle event rather than after `behavior.completed`.
      Ported from activegraph.runtime.context_reads + test_context_read_tracing.py —
      `spec/chronicle/context_read_spec.cr`, `spec/chronicle/context_read_runtime_spec.cr`.
- [x] `Runtime#errors` — `Chronicle::BehaviorFailure` value struct +
      `Runtime#errors` projection (CONTRACT v1.0.3 #3): the store is the
      source of truth and `errors` is a read-on-access projection of every
      `behavior.failed` event into a `BehaviorFailure` (behavior, event_id,
      reason — the v0.6 #11 code when present, exception_type, message,
      failed_event_id tying back to the underlying event). `invoke_pack_behavior`
      now records a durable `behavior.failed` event on a failing behavior
      (instead of re-raising out of dispatch, matching upstream `_invoke` —
      the run continues) and `record_behavior_failed` writes the
      upstream-compatible payload fields (`behavior`, `event_id`, `reason`,
      `exception_type`, `message`; `trigger_event_id`/`error_class` retained
      for back-compat). The `reason` field is populated for `LLMBehaviorError`.
      Ported from activegraph.runtime.runtime `errors`/`BehaviorFailure` +
      test_v1_0_3_behavior_failed_ux.py — `spec/chronicle/behavior_failure_spec.cr`.
- [x] `doc_url_for_reason` — `Chronicle::RuntimeReason.doc_url_for_reason`
      maps a v0.6 #11 reason code to its framework error doc-page URL
      (`llm.*` → `llm-behavior-error`, `tool.*` → `tool-error`,
      `budget.*` → `budget-exhausted`, anything else — including
      `exception.*` generic catches — → `execution-error`), rooted at
      `DOCS_BASE_URL`. The `behavior.failed` event payload now carries the
      `doc_url` field (v1.0.3 #3 — the WARNING log line's More: URL).
      Ported from activegraph.runtime.runtime._doc_url_for_reason +
      test_v1_0_3_behavior_failed_ux.py — `spec/chronicle/doc_url_for_reason_spec.cr`.
- [x] LLM retry helpers — `Chronicle::RuntimeReason.transient_llm_reason?`
      (llm.network_error / llm.rate_limited are transient, retried with
      backoff; auth/request are terminal — CONTRACT v1.3 #3) and
      `llm_retry_delay_seconds` (a provider-supplied `retry_after_seconds`
      is honored and clamped to the maximum when positive; otherwise
      exponential backoff `initial * 2**attempt_index` capped at the
      maximum; `initial <= 0` yields 0).       Ported from activegraph
      runtime/runtime.py `_is_transient_llm_reason` / `_llm_retry_delay_seconds`
      (unit-tested directly; the full flaky-provider retry loop is a
      platform-edge integration) — `spec/chronicle/llm_retry_spec.cr`.
- [x] Per-turn prompt hash — `Chronicle::Prompt.hash_turn_prompt` builds the
      per-turn LLM cache key (CONTRACT v0.7 per-turn cache decision,
      upstream `_hash_turn_prompt`): SHA-256 of the sorted-key canonical
      JSON over {model, system, running messages list, output schema,
      tokens, temperature, top_p, deterministic, tools, + mode when native}.
      The running messages list makes each turn in a tool loop hash
      distinctly; tools contribute so a gained/lost tool changes the key.
      Implemented as `hash_payload(canonical_prompt_payload(...))` with the
      running turn's messages. Ported from activegraph runtime/runtime.py —
      `spec/chronicle/hash_turn_prompt_spec.cr`.
- [x] `maybe_object_id` — `Chronicle::RuntimeReason.maybe_object_id(event)`
      extracts the object id referenced by an event payload for lifecycle
      tags (`behavior.started` now carries `triggering_object_id`).
      Divergence: upstream reads the nested `object.id` (its payloads nest
      under `object`); Chronicle's flat payloads carry `id` at the top level,
      so       the helper reads `payload["id"]`. Returns nil for events without
      one (goal.created) or non-object payloads. Ported from activegraph
      runtime/runtime.py `_maybe_object_id` — `spec/chronicle/maybe_object_id_spec.cr`.
- [x] `first_goal` — `Chronicle::RuntimeReason.first_goal(events)` returns
      the first `goal.created` event's goal text, or nil when the run has no
      goal (a raw graph-only run). Ported from activegraph
      runtime/runtime.py `_first_goal` — `spec/chronicle/first_goal_spec.cr`.
- [x] `is_lifecycle` — `Chronicle::RuntimeReason.lifecycle?` (upstream
      `_is_lifecycle`): true for `behavior.*`, `relation_behavior.*`,
      `runtime.*`, and `context.read` (v1.10 #1 — per-execution bookkeeping
      a tracing-off verify pass never reproduces). Wired into
      `ReplayEngine.assert_strict_replay` so strict replay skips lifecycle
      events when comparing recorded vs re-run streams — a verify pass with
      tracing off no longer diverges on `context.read`/lifecycle markers.
      Note this is the NARROW replay-exclusion predicate, distinct from the
      runtime's broader private `lifecycle?` (which also suppresses
      `llm.*`/`tool.*`/etc. for pattern matching). Ported from activegraph
      runtime/runtime.py `_is_lifecycle` — `spec/chronicle/is_lifecycle_spec.cr`.
- [x] `SinkConfig` + constructor sink normalization — `Chronicle::SinkConfig`
      value struct (sink, name?, queue_capacity=1024, overflow_policy=
      DROP_NEWEST) with locked defaults and validation (empty name, capacity
      must be a positive integer). `Runtime(sinks: [...])` normalizes the
      configs (default name from the sink class, duplicate-name rejection
      BEFORE any attach so a late failure never leaks a partially-attached
      sink) and attaches each via the graph — sinks accept future events
      only, history reconstructed by load/fork is never offered. Ported from
      activegraph sinks/base.py SinkConfig + runtime/runtime.py
      `_normalize_sink_configs` + test_event_sinks.py —
      `spec/chronicle/sink_config_spec.cr`.
- [x] `most_recent_run_id` — `Chronicle::RuntimeReason.most_recent_run_id(path)`
      returns the most recent run id in a SQLite store (used by
      `Runtime.load` to resume the latest run), via the already-ported
      `SQLiteEventStore.list_runs` (ordered by created_at; nil for an empty
      store). Ported from activegraph runtime/runtime.py
      `_most_recent_run_id` + store/sqlite.py `most_recent_run_id` —
      `spec/chronicle/most_recent_run_id_spec.cr`.
- [x] `recorded_wall_stop` — `Chronicle::RuntimeReason.recorded_wall_stop(events)`
      returns the validated cooperative wall-stop boundary
      `(accepted_sequence, max_seconds_limit)` from a
      `runtime.budget_exhausted` event whose `exhausted_by` is `max_seconds`
      (nil when no such event). A malformed `stop_position.accepted_sequence`
      (non-negative integer) raises `ReplayDivergenceError`. Used by strict
      replay to pin divergence at the right position. Ported from activegraph
      runtime/runtime.py `_recorded_wall_stop` —
      `spec/chronicle/recorded_wall_stop_spec.cr`.
- [x] `non_replayable_llm_attempt_event_ids` —
      `Chronicle::RuntimeReason.non_replayable_llm_attempt_event_ids(events)`
      collects the failed LLM-attempt request/response ids so strict replay
      replays from the successful `llm.responded` cache entry rather than
      requiring the provider to fail again (upstream
      `_non_replayable_llm_attempt_event_ids`). Divergence: upstream marks
      failed attempts via `llm.responded` with an `error` payload; Chronicle
      emits a separate `llm.failed` event, so the helper collects the
      `llm.failed` id plus its `caused_by` request id. Ported from activegraph
      runtime/runtime.py — `spec/chronicle/non_replayable_llm_ids_spec.cr`.
- [x] Runtime sink surface — `Runtime#add_sink` / `remove_sink` /
      `sink_statuses` / `flush_sinks` / `close_sinks` (CONTRACT v1.8)
      delegate to the attached graph (raising `IncompatibleRuntimeState`
      when no graph is attached for add). Historical events reconstructed
      by load/fork are never offered; lifecycle events ARE delivered to
      sinks. Added `GraphProjection#close_sinks` (detach + close all).
      Ported from activegraph.runtime.runtime Runtime.add_sink/remove_sink/
      sink_statuses/flush_sinks/close_sinks + test_event_sinks.py —
      `spec/chronicle/runtime_sinks_spec.cr`.
- [x] Cooperative quantum drain — `Runtime#run_quantum(max_queue_events,
      max_seconds)` returning `Chronicle::RunQuantumResult` (CONTRACT v1.10
      #3): single-writer hosts can interleave reads/commands between quanta.
      Bounds are checked between queue events (one behavior invocation stays
      atomic); the dispatch cursor advances only `max_queue_events` pending
      events per quantum and the loop stops at the deadline. When work
      remains, no `runtime.idle` marker is emitted (no false idle); the
      idle/budget marker is emitted exactly when the quantum actually
      reaches that state. `RunQuantumResult` carries process observations —
      `queue_events_processed`, `elapsed_seconds` (never written to the log,
      so scheduling stays replay-deterministic), `queue_depth`,
      `max_queue_depth`, `delayed_depth`, `idle`, `budget_exhausted`.
      Invalid bounds (`max_queue_events < 1`, non-finite/`<= 0`
      `max_seconds`) raise `ArgumentError`. The queue excludes lifecycle
      events (`behavior.*`, `runtime.*`, `llm.*`, `tool.*`, ...) — they are
      consumed without counting toward the bound or `queue_depth`, matching
      upstream's `_on_event` suppression. The exact 6-quanta pin is restored:
      the harness registers the chain behavior directly (no `pack.loaded`
      event, mirroring upstream's global `@behavior` decorators — pack.loaded
      is queue-visible per CONTRACT v0.9 #13, so loading a pack would occupy
      one slot). Restart recovery is faithful: `resume_from_store` rebuilds
      the cursor from the last `runtime.idle` plus the `fired_on` set of
      event ids referenced by `behavior.started`, so a FRESH runtime over a
      partially-drained store skips already-fired events and the chain
      completes exactly once (upstream `Runtime.load` +
      `_requeue_unfired`). `behavior.started` is now emitted for plain and
      relation behaviors too (upstream `_invoke`), carrying `event_id` for
      the fired_on mechanism. Ported from activegraph.runtime.runtime
      `run_quantum`/`RunQuantumResult` + test_run_quantum.py (CONTRACT v1.10
      #3) — `spec/chronicle/run_quantum_spec.cr`. Note: this is a
      keyword-only overload alongside Chronicle's prompt-driven
      `run_quantum(prompt, steps)`.

## Phase 4 — LLM layer + replay cache

- [x] Content-addressed store — `Chronicle::EffectArtifactStore`/`LLMCache` base
      — `spec/chronicle/effect_artifact_spec.cr`, `llm_cache_spec.cr`
- [x] Wire the LLM cache into replay/fork: `LLMCache.from_events` harvests
      `llm.responded` (via `caused_by` → `llm.requested` request_hash), skips
      error-shaped attempts, and `Runtime.load(replay_llm_cache: true)`
      pre-populates it. `Runtime` consults the cache before any provider call
      and serves hits with `cache_hit: true` recorded; provider successes are
      recorded back into the cache. `replay_strict: true` raises
      `ReplayDivergenceError` on prompt-hash mismatch — `llm/cache.py`,
      `runtime.py` — `spec/chronicle/llm_cache_wiring_spec.cr`
- [-] Provider adapters (Anthropic/OpenAI/native structured output) — deferred;
      `Chronicle::ModelExecutor` already routes through registered executors —
      `llm/anthropic.py`, `llm/openai.py`, `llm/native.py`
- [x] Wire protocol (request/response types, canonical serialization,
      `prompt_hash`) — `llm.requested` events now carry `prompt_hash` (the
      canonical prompt digest, upstream `turn_hash`) alongside `request_hash`
      so trace consumers can key on the prompt identity like upstream does.
      `EffectRequest`/`ModelEffectRequest` remain structs carrying the
      canonical `content_hash`. Ported from activegraph runtime.py
      requested_payload — `spec/chronicle/llm_cache_wiring_spec.cr`.
      `llm/types.py` provider types and `llm/parsing.py` stay deferred.
- [x] LLM data types — `Chronicle::LLMMessage` / `Chronicle::ToolCall` /
      `Chronicle::LLMResponse` structs (from `llm/types.py`, v0.7 shapes)
      plus a `Chronicle::Role` enum (`user`/`assistant`/`tool`). These are
      plain `JSON::Serializable` structs: the wire form comes from `to_json`
      / `from_json`, nilable fields (`tool_use_id`, `tool_name`,
      `tool_calls`, `seed`, `parsed`) are omitted when absent so single-turn
      fixtures keep byte-identical serialization, and the `Role` enum uses
      Crystal's default underscored-member-name serialization. Upstream's
      `to_dict` dataclass idiom and `_parsed_to_jsonable` Pydantic adapter
      are N/A (divergence) — structs serialize themselves —
      `spec/chronicle/llm_types_spec.cr`.
- [-] Embedding — deferred — `llm/embedding.py`, `llm/embedding_cache.py`
- [x] LLM provider protocol + fixture providers — `Chronicle::LLMProvider`
      abstract class (CONTRACT v0.6 #3 + v1.0.2 #1): `complete(output_schema :
      T.class)` generic, `estimate_cost`, `count_tokens`, `recognizes_model`,
      `supports_native_structured_output` (v1.3 #1), `default_model`.
      `Chronicle::RecordedLLMProvider` reads fixtures keyed by prompt hash
      (`llm.fixture_missing` → `LLMBehaviorError` with `prompt_hash`/
      `fixtures_dir` payload extras, no silent live fallthrough);
      `Chronicle::RecordingLLMProvider` wraps an inner provider and mirrors
      each call to a fixture file with `recorded_at` OUTSIDE the hashed
      `prompt` payload (CONTRACT v0.6 #12 + decision-3 adjustment), so the
      same prompt always overwrites one file. The hash key is
      `Prompt.hash_payload(Prompt.canonical_prompt_payload(...))` — SHA-256
      of sorted-key canonical JSON over {model, system, messages,
      output_schema_name/json, max_tokens, temperature, top_p, deterministic,
      tools, + mode when native}. Ported from activegraph llm/provider.py +
      llm/recorded.py + test_llm_provider_fixtures.py —
      `spec/chronicle/llm_recorded_spec.cr`. Divergence: `cost_usd` is a
      String (upstream Decimal); `parsed` stays `JSON::Any` (no runtime
      Pydantic re-validation); fixture file I/O lives at the platform edge
      (`llm_recorded.cr` is an I/O-boundary path), the pure hash logic in
      `prompt.cr` stays Sans-IO.
- [x] Prompt assembler + view serializer — `Chronicle::Prompt` (CONTRACT
      v0.6 #6, #13, #20): every prompt is assembled from four locked sources
      — system (frame goal → frame constraints → behavior description →
      output-schema reminder), view (Markdown block of objects + relations +
      recent events, format snapshot-pinned), event (volatile-stripped
      canonical JSON: `provenance`/`timestamp`/`run_id` dropped recursively),
      and a one-sentence `instruction` derived from `creates=` /
      `output_schema=`. `AssembledPrompt` (system, `Array(LLMMessage)`,
      model, tokens, temperature/top_p, deterministic, schema name+json,
      sections) with a stable SHA-256 `hash` over sorted-key canonical JSON —
      the replay-cache key. `schema_to_json(schema : T.class)` derives the
      JSON Schema from a `JSON::Serializable` struct at compile time via the
      `json-schema` shard (typed fields + enums, replacing Pydantic's
      `model_json_schema`); `schema_name(T)` derives the name from the type.
      `example_instance_from_schema` walks `$defs`/`enum`/`const`/`anyOf`/
      `oneOf`/`type` with bounded recursion. `prompt_template=` (str.format-
      style `{system}`, `{view}`, `{event}`, `{instruction}`) is the only
      escape hatch; unknown placeholders raise `PromptTemplateError`.
      Divergence: `_event_summary` reads Chronicle's flat `object.created` /
      `relation.created` payloads (`id`/`from_id`/`to_id`/`type`) where
      upstream nests under `object`/`relation`; schema blocks render compact
      sorted JSON rather than Python's `indent=2`. Ported from activegraph
      llm/prompt.py + test_llm_prompt.py — `spec/chronicle/prompt_spec.cr`.
- [x] Provider-boundary wire helpers — `Chronicle::Wire` (CONTRACT v1.3 #3):
      tool-name sanitization for the providers' `^[a-zA-Z0-9_-]+$` wire
      alphabet (`sanitize_tool_name`: `.` → `__`, other unsafe chars → `_`,
      wire-safe names byte-identical) with an explicit per-request reverse
      map (`build_tool_name_map`/`restore_tool_name`) that raises
      `ToolNameCollisionError` when two canonical names collide — never a
      blind string replace, so a tool legitimately named `pack__tool` cannot
      be mangled. Plus the v1.3 #3 exception taxonomy:
      `classify_provider_exception`/`classify_provider_failure` map provider
      SDK failures to `llm.rate_limited` (429/name), `llm.auth_error`
      (401/403/auth/permission-denied), `llm.request_error` (other 4xx +
      bad-request/unprocessable/not-found name heuristics), and
      `llm.network_error` (fallback, transient) — matching upstream's
      ordering and the `terminal_reason?` retry-set split (auth/request
      terminal, network/rate-limit transient). Ported from activegraph
      llm/wire.py + test_llm_wire.py unit cases (the full-runtime
      auth/request-not-retried integration tests map to
      `Chronicle::RetryableProviderError` handling in the platform-edge
      `ModelExecutor` path, already covered) —
      `spec/chronicle/wire_spec.cr`.

## Phase 5 — Tools

- [x] Tool base + registry — `Chronicle::Tool` (name, description, callable),
      `Chronicle::ToolRegistry` (@tool-style snapshot/clear) — `tools/base.py`,
      `tools/decorators.py` — `spec/chronicle/tools_spec.cr`
- [x] `graph_query` tool — `Chronicle.make_graph_query_tool(graph)` bound to a
      `GraphProjection`, returns object refs with limit/truncated —
      `tools/graph_query.py` — `spec/chronicle/tools_spec.cr`
- [x] Wire tools through the runtime — `Runtime` accepts `tools`; `drive_model`
      passes tool names as `allowed_tools`; `drive_tools` invokes tools by name,
      records `tool.requested`/`tool.responded`, and serves `ToolCache` hits;
      `Runtime.load(replay_tool_cache: true)` pre-populates the cache —
      `tools/cache.py` — `spec/chronicle/tools_spec.cr`
- [x] `web_fetch` tool fail-closed gate (CONTRACT v0.7 #16, v1.8 #7) —
      `Chronicle::ExternalIOMode` enum (forbid / runtime_recorded /
      live_unrecorded), `WebFetchInput`/`WebFetchOutput` value structs, and
      `make_web_fetch_tool` — a non-deterministic tool that refuses to run
      unless `live_unrecorded` is explicitly allowed, before any network
      contact (production default hard-fails; the HTTP body is injected at the
      platform edge). Ported from activegraph.tools.web_fetch +
      test_web_fetch_hardening — `spec/chronicle/web_fetch_spec.cr`.
      `tools/web_fetch.py` live-HTTP wiring stays at the platform edge.
- [x] Tool result caching via the existing `Chronicle::ToolCache` (recorded replay)
- [x] Fixture-based tool invokers — `Chronicle::DirectToolInvoker` /
      `RecordedToolProvider` / `RecordingToolProvider` + `CachedToolResponse`
      (CONTRACT v0.7 #15, mirroring `llm/recorded.py`). Fixtures live at
      `<dir>/<tool_name>/<args_hash>.json` with `recorded_at` OUTSIDE the
      hashed args. `DirectToolInvoker` is the production invoker: calls the
      tool body with timing and exception trapping (explicit `ToolError`
      propagates unchanged; other exceptions become
      `tool.execution_error`). `RecordingToolProvider` wraps an inner
      invoker and persists each response; `RecordedToolProvider` reads the
      fixture and raises `ToolError` (`tool.fixture_missing` with
      `tool`/`args_hash`/`fixtures_dir` extras) on a miss. The hash key is
      `ToolCache.hash_tool_call` — SHA-256 over
      `{tool, canonicalize_args(args)}` where `canonicalize_args` re-encodes
      JSON args with sorted keys so dict order never changes the hash.
      `ToolError` upgraded to carry `reason`/`payload_extras` (the
      `web_fetch` raise sites updated to the two-arg form). Ported from
      activegraph tools/recorded.py + tools/cache.py + test_tools.py —
      `spec/chronicle/tool_recorded_spec.cr`. Divergence: `cost_usd` is a
      String (upstream Decimal); `_normalize_args`/`_decimal` Pydantic/
      Decimal helpers are N/A (args are JSON strings); fixture file I/O lives
      at the platform edge (`tool_recorded.cr` is an I/O-boundary path).

## Phase 6 — Sinks + observability

- [x] Sink base + bounded FIFO + overflow policy — `Chronicle::Sink`, `SinkHandle`,
      `OverflowPolicy` (drop_newest/drop_oldest/fail_sink), `SinkState`,
      `DeliveryContext`, `SinkStatus` — `sinks/base.py` — `spec/chronicle/sinks_spec.cr`
- [x] Graph sink surface (completes Phase 1) — `GraphProjection#add_sink`/
      `remove_sink`/`flush_sinks`/`sink_statuses`; `emit` offers to sinks before
      listeners — `sinks/dispatch.py`
- [x] Testing sink + JSONL sink — `Chronicle::TestingSink`, `Chronicle::JSONLSink` —
      `sinks/testing.py`, `sinks/jsonl.py` — `spec/chronicle/sinks_spec.cr`
- [x] Sink conformance cases (order, unicode round-trip, bounded overflow,
      status, remove) — `spec/chronicle/sinks_spec.cr`
- [x] Observability status snapshot — `Runtime#status` returns a typed
      `Chronicle::RuntimeStatus` value object (struct with `copy_with`),
      mirroring upstream's frozen `RuntimeStatus` dataclass (CONTRACT v0.8
      #11): `RuntimeState` enum (idle/running/stopped/exhausted) derived from
      the log's last terminal marker, `events_processed`, `BudgetSnapshot`,
      `FrameSnapshot`, `registered_behaviors` (`BehaviorInfo` with name/kind/
      subscribed_to/pattern/activate_after), and `recent_events`
      (`EventSummary` tail), plus `to_h` matching upstream `status_to_dict`.
      Ported from activegraph.observability.status — `spec/chronicle/status_spec.cr`.
      Metrics/logging/prometheus/otel dashboards stay deferred — `observability/*`.
- [x] Metrics protocol + standard table — `Chronicle::Metrics` abstract
      protocol (CONTRACT v0.8 #8–#10): three non-throwing methods
      (`counter`/`histogram`/`gauge`), `NoOpMetrics` default, `MetricSpec`
      (name/kind/tags/description), and `MetricsTable` with the full 24-entry
      standard metric list (`METRIC_NAMES`/`by_name` — events emitted,
      behaviors invoked/failed/duration, LLM calls/cache/failed/tokens/cost,
      tools calls/cache/failed/duration, queue/sink/budget gauges, pattern
      counters, replay-divergence) and `validate_cardinality_rule`
      (CONTRACT v0.8 #C4: `run_id` is gauge-only — a counter/histogram
      declaring it raises `MetricsError`; validated at load). Runtime wiring:
      `Runtime` accepts a `metrics` instance (default `NoOpMetrics`),
      `append_event` fires `activegraph_events_emitted_total` with an
      `event_type` tag, and `invoke_pack_behavior` fires
      `activegraph_behaviors_invoked_total` /
      `activegraph_behaviors_duration_seconds` /
      `activegraph_behaviors_failed_total` (reason = exception class) around
      every behavior invocation. Ported from activegraph
      observability/metrics.py + test_observability_metrics.py (the
      prometheus/otel adapters and remaining runtime emission points stay
      deferred) — `spec/chronicle/metrics_spec.cr`.
- [x] Structured logging — `Chronicle::Logging` (CONTRACT v0.8 #6–#7, #16):
      the documented operator-facing log schema is the contract —
      `LOG_FIELDS` (timestamp, level, logger, message, run_id, event_id,
      behavior, tool, model, cache_hit, cost_usd, latency_seconds, reason,
      error_type, error_message, doc_url; fields omitted when absent, never
      nulled). `format_line` renders one compact JSON object per record:
      required fields always present, documented extras passed through,
      undocumented fields dropped. `runtime_log_extra` builds the extras dict
      (nil values dropped; stdlib log-record attribute collisions renamed
      with an `ag_` prefix), and `set_payload_redactor`/`redact_payload`
      install/apply an idempotent payload redactor. Divergence: upstream's
      `configure_logging`/`get_logger` (stdlib logging handler setup) are
      platform-edge — the Sans-IO core owns only the pure formatter/extras/
      redaction logic, and the timestamp is supplied by the caller. Ported
      from activegraph observability/logging.py +
      test_observability_logging.py — `spec/chronicle/logging_spec.cr`.
- [x] Sink conformance as a reusable mixin — extracted the shared conformance
      cases (live delivery order + context, unicode, bounded overflow,
      remove-sink, raising-sibling isolation, no-redeliver-history) into
      `SinkConformance.define_tests` (mirroring `GraphStoreConformance`), run
      against `TestingSink`. The thread-based "shared sink across concurrent
      runs" case is N/A for the Sans-IO single-threaded core. Ported from
      activegraph sinks/conformance.py (CONTRACT v1.8 #5) —
      `spec/chronicle/sink_conformance.cr`, `spec/chronicle/sinks_spec.cr`.

## Phase 7 — Packs + policy

The pack system is ported with Crystal annotations standing in for Python's
pack-aware decorators: a pack module `include Chronicle::Packs::DSL`, annotates
its structs/methods with `@[Behavior]`, `@[LLMBehavior]`, `@[RelationBehavior]`,
`@[Tool]`, `@[ObjectType]`, `@[RelationType]`, and calls the `pack` macro, which
collects them at compile time into a frozen `Pack` manifest. Nothing registers
globally (CONTRACT v0.9 #3).

- [x] Pack value objects — `Chronicle::Packs::ObjectType`, `RelationType`,
      `PackPolicy`, `PackPrompt` (content hash), `CapabilityDecl`, `Pack`
      (identity by `(name, version)`, name/version + uniqueness validation,
      `prompt_manifest`) — `packs/__init__.py` —
      `spec/chronicle/packs_spec.cr`
- [x] Annotations + DSL macro — `@[Behavior]` / `@[LLMBehavior]` /
      `@[RelationBehavior]` / `@[Tool]` / `@[ObjectType]` / `@[RelationType]`
      collected by `Chronicle::Packs::DSL.pack`; pack-local, no global
      registration — `packs/__init__.py` decorators —
      `spec/chronicle/packs_dsl_spec.cr`
- [x] Prompt loading — `load_prompts_from_dir` (TOML frontmatter, SHA-256
      content hash, duplicate/hidden/symlink rules, `PackPromptLoadError`) —
      `packs/__init__.py` — `spec/chronicle/packs_prompt_spec.cr`
- [x] Typed settings via macro — a settings struct `include JSON::Serializable`
      + `Chronicle::Packs::SettingsSchema`; defaults, required-field
      enforcement, dict coercion, canonical dump, `PackSettingsMissingError` —
      `packs/__init__.py` EmptySettings —
      `spec/chronicle/packs_dsl_spec.cr`
- [x] Loader lifecycle — `Chronicle::Packs::Loader` +
      `PackRuntimeState`; idempotency on `(name, version)`, version conflict,
      pre-emptive conflict scan (behaviors/tools/object types/relation
      types/policies + `export_globally` tools), canonical prefixing, settings
      injection, schema attach, short-name ambiguity, `pack.loaded` event with
      full payload — `packs/loader.py` — `spec/chronicle/packs_dsl_spec.cr`
- [x] Graph schema validators — object validation raises
      `PackSchemaViolation` (post-load only); relation source/target type
      checks — `packs/loader.py` + `core/graph.py` — `spec/chronicle/packs_dsl_spec.cr`
- [x] Behavior dispatch — `Runtime#run_until_idle` drains new log events
      through matching pack behaviors (typed-settings injection Form 1,
      `ctx.settings` Form 2, `ctx.pack_settings` Form 3, `where` predicates)
      — `runtime/runtime.py` — `spec/chronicle/packs_dsl_spec.cr`
- [x] Discovery registry — `Chronicle::Packs::Registry` (`discover` /
      `load_by_name` / `clear_discovery_cache`, `PackNotFoundError`); the
      Crystal analogue of the `activegraph.packs` entry-point group —
      `packs/__init__.py` — `spec/chronicle/packs_discovery_spec.cr`
- [x] Manifest — `load_manifest` (aggregated `PackManifestError` violations,
      PEP 440 syntax, reserved signature rejection), `verify_surface`
      (two-way, capabilities + risk/action-class agreement),
      `compute_content_hash` / `compute_bundle_hash` (§4 byte stream,
      symlink/`.hidden`/`.pyc`/`__pycache__` rules),
      `verify_content_hash` / `verify_bundle_hash` —
      `packs/manifest.py` — `spec/chronicle/packs_manifest_spec.cr`
- [x] Scaffold — `normalize_pack_name` (kebab→snake) + `scaffold_pack`
      (runnable Crystal pack layout with annotations DSL + smoke spec) —
      `packs/scaffold.py` — `spec/chronicle/packs_scaffold_spec.cr`
- [x] Pack capabilities — `CapabilityDecl` validation (closed risk/action
      classes) and `capabilities` block in the `pack.loaded` payload —
      `packs/__init__.py` + `packs/manifest.py` —
      `spec/chronicle/packs_manifest_spec.cr`
- [x] LLM behavior *execution* dispatch — `@[LLMBehavior]` handlers auto-run
      through the LLM effect pipeline (`behavior.started` -> llm.requested ->
      llm.responded -> handler -> `behavior.completed` / `behavior.failed`),
      reusing the cache + fallback path — `runtime/runtime.py` —
      `spec/chronicle/llm_behavior_runtime_spec.cr`
- [-] Diligence reference pack — deferred — `packs/diligence/*`
- [x] `pack.settings_overridden` fork override — `load_pack` now applies
      recorded `pack.settings_overridden` events for the pack onto its settings
      (the CLI `fork --set` surface): the parent prefix stays intact and the
      fork carries an auditable override that merges at pack registration time.
      Ported from activegraph.packs.loader._apply_recorded_settings_overrides —
      `spec/chronicle/settings_override_spec.cr`.
- [x] `ctx.propose_object` — behavior-context deferred object creation behind
      policy approval (upstream `Context.propose_object`): `BehaviorContext`
      carries an optional runtime backref (a `propose_object` Proc wired by
      `invoke_pack_behavior` — Crystal can't hold the generic `Runtime(M)` in
      a union), so a pack-owned behavior can route a gated `object_type`
      write through `propose_object(type, data, reason:)` → `Runtime#propose_object`
      (approval.proposed event + pending approval) and `approve_pack(id)`
      materializes it. Calling `ctx.propose_object` on a context built
      outside a runtime raises `RuntimeContextRequiredError` (an
      `ExecutionError` with the structured format + doc slug
      `runtime-context-required-error`). This completes the
      approve-materialization of gated object types. Divergence: upstream's
      `ctx.embed` stays deferred (embedding provider not ported); the
      runtime-required error pattern is shared via `propose_object`. Ported
      from activegraph.runtime Context.propose_object +
      exec_errors.RuntimeContextRequiredError + test_errors_format.py /
      _legacy_approval_scenario.py — `spec/chronicle/context_methods_spec.cr`.
- [x] Manifest warning tier on `load_pack` (CONTRACT v1.6 #1) — when a
      `manifest_path` is supplied to `load_pack`, the loader runs
      `load_manifest` + `verify_surface` and records a structured warning
      (via `Runtime#pack_warnings`) on violations — the pack still loads,
      never an error before 2.0; absent manifest is silent. Chronicle can't
      auto-locate a sibling `manifest.toml` (no `__file__`), so the path is an
      explicit `load_pack(manifest_path:)` arg. Ported from
      activegraph.packs.loader._warn_on_manifest_violations —
      `spec/chronicle/manifest_warning_spec.cr`.

## Phase 8 — Frames wiring

- [x] `Chronicle::Frame` value + `FrameStack` — `spec/chronicle/frame_spec.cr`
- [x] `frame_id : String?` on `Chronicle::Event` envelope (canonical_json +
      `EventLogCodec` round-trip) — `spec/chronicle/frames_spec.cr`
- [x] Runtime `push_frame`/`pop_frame`/`current_frame_id` lifecycle —
      `frame.py` — `spec/chronicle/frames_spec.cr`
- [x] Events recorded inside a frame carry `frame_id` (`chat.message`,
      `pack.loaded`, ...); `events_in_frame(frame_id)` groups them — `frame.py`
- [x] Group frames in trace export — `Runtime#export_trace` emits a `frames`
      object mapping each frame_id to its events (in log order) alongside the
      flat `events` list (preserved for backward compatibility); events without
      a frame_id are not grouped. Chronicle-specific enhancement (upstream
      lists all events flatly; `events_in_frame` is the grouping surface) —
      `spec/chronicle/trace_frames_spec.cr`.

## Phase 9 — Sandbox + CLI + trace printer

- [x] Trace causal chain — `Chronicle::Trace.causal_chain(events, graph, object_id)`
      walks `caused_by` back to the goal with cycle detection — `trace/causal.py`
      — `spec/chronicle/trace_spec.cr`
- [x] CLI trace command — `chronicle-cli trace --file <log> --object <id>` renders
      the causal chain from a recorded log — `trace/printer.py` —
      `spec/chronicle/cli_spec.cr`
- [x] Trace structured accessors — `Runtime#trace` returns a
      `Chronicle::TraceFacade` (v1.3; named to avoid clashing with the
      `Chronicle::Trace` module that owns `causal_chain`): `trace.events`
      returns the run's events in log order as a copy (each carries the id
      `Runtime#fork`'s `at_event=` expects), and `trace.failures` returns
      the `behavior.failed` events. `record_behavior_failed` now captures
      the full exception `traceback` string in the event payload (v1.0.3),
      so `trace.failures` can surface it. Divergence: Crystal backtraces
      name the failing method frame rather than embedding the source line.
      Ported from activegraph Runtime.trace + trace/printer.py Trace +
      test_trace_accessors.py — `spec/chronicle/trace_accessors_spec.cr`.
- [-] Sandbox executor/conformance (`_child`, `executor`, `conformance`) —
      deferred — `sandbox/*`
- [x] CLI renderers — the `diff` subcommand now renders the upstream-style
      structural summary (shared/parent-only/fork-only/divergent counts) plus
      `divergent objects:` / `divergent relations:` summary lines, computed via
      `Chronicle::Diff` between the two replayed logs. The `DiffFormatter`
      (GraphDiff) renderer remains for the projection-level surface. Ported
      from activegraph cli/main.py `cmd_diff` —
      `spec/chronicle/cli_spec.cr`. `cli/quickstart.py` renderers stay
      deferred.

## Phase 10 — External GraphStore backends (stretch)

- [x] SQLite-backed `GraphStore` — `Chronicle::SQLiteGraphStore` stores entities as
      JSON::Serializable rows and passes the full conformance suite —
      `spec/chronicle/graph_store_sqlite_spec.cr`
- [x] `graph_store=` injection seam — `GraphProjection.new(store:)` already
      accepts any `GraphStore` (Phase 5)
- [-] Postgres / FalkorDB GraphStore pushdown — deferred — `store/postgres.py`,
      `store/falkordb.py` (any backend passing the conformance suite is
      interchangeable)

---

## Intentional Divergence

- **Ordered comparisons on incomparable types:** matching activegraph, ordered
  comparisons (`<`, `>`, `<=`, `>=`) raise on mixed/incomparable non-nil values.
  Chronicle raises `Chronicle::PatternTypeError` (analogous to Python's `TypeError`).
  Nil operands still evaluate to no-match. Residual: Python compares arrays
  lexicographically; Chronicle raises for array operands. Equality ops use
  numeric-aware comparison (`3 == 3.0` is true).
- **`objects(where:)` ordered ops guard both operands.** Upstream guards only
  `a` (`a is not None and a > b`); Chronicle returns no-match for any nil operand,
  consistent with the pattern matcher.
- **JSON storage shape:** upstream `Object.data` is a Python dict; Chronicle stores
  it as a canonical JSON `String`. WHERE/path semantics are identical.
- **Time/randomness allowed in the core.** Only routing must be deterministic.
  `IDGen#run`/ULID uses wall clock + `Random::Secure`; the core I/O-safety gate
  forbids only direct I/O, environment access, and process capabilities (Sans-IO).
- **Projection writes through its GraphStore in place**, mirroring upstream
  `Graph._state` mutation; replay builds a fresh projection.
- **Pack decorators are compile-time annotations.** Python's
  `@behavior`/`@tool`/`@ObjectType` become Crystal `@[Behavior]`/`@[Tool]`/
  `@[ObjectType]` annotations collected by the `Chronicle::Packs::DSL.pack`
  macro. Behaviors/tools are instance defs in the pack module (the DSL
  `extend self`s it); settings injection is resolved at compile time from the
  def's `settings` parameter. No runtime signature introspection (no dynamic
  `**kwargs` injection).
- **Cross-pack settings (`ctx.pack_settings`) return the canonical settings
  Hash**, not a typed object — typed cross-pack access isn't expressible in
  Crystal. Behavior-local settings stay fully typed.
- **Pack tools accept only `args`** (no `ctx`/settings parameter yet); the DSL
  raises at compile time if a `@[Tool]` method declares other parameters.
- **Object/relation schemas use `JSON::Serializable` + a DSL-generated
  validator**; Pydantic `Field(ge=...)`-style constraint annotations aren't
  supported (type/requiredness checks are).
- **Discovery uses an explicit `Registry`** (the DSL registers the pack when
  its module is required) instead of Python entry points; `discover()` caches
  per process and `register`/`clear_discovery_cache` invalidate.
- **`_pack_local` is enforced at compile time** (only the DSL builds pack
  objects) rather than via a runtime flag on every `Behavior`/`Tool`.
- **LLM behavior execution dispatch runs through the LLM effect pipeline**;
  structured-output schema typing is not yet ported, so `@[LLMBehavior]`
  handlers receive the raw output string.
- **Pack tool/behavior short-name lookup** raises
  `Chronicle::Packs::AmbiguousBehaviorError` / `BehaviorNotFoundError`
  (Chronicle-specific types) mirroring upstream's `ValueError`/`LookupError`
  surface.
- **Dev-override validation raises `Chronicle::DevOverrideError`**
  (a `DomainError`) instead of upstream's bare `ValueError`; gate/authority
  semantics are identical.
- **Serde encode-side strictness is compile-time in Crystal.** Upstream
  `store/serde.py` coerces Python values to JSON at emit-time (Decimal →
  string, datetime → ISO 8601, set → sorted list) and raises
  `NonSerializableEventError` with a walked offender path
  (`_find_non_serializable`). Chronicle's `Event.payload` is already a
  canonical JSON `String` and `JSON::Any`/`String` cannot hold non-JSON
  values, so `Serde.encode_payload` never fails at runtime;
  `NonSerializableEventError` remains the fail-fast gate surface (wired into
  `GraphProjection#emit` when a store is attached) and the decode-side
  `CorruptedEventPayloadError` is the reachable runtime error. The upstream
  `_default`/`_find_non_serializable` walkers are N/A and skipped in the
  ledger.
- **Provider exception classification reads `status_code` structurally.** The
  upstream `classify_provider_exception` reads the SDK exception's
  `status_code` attribute via `getattr`; Crystal uses
  `exc.responds_to?(:status_code)` and class-name heuristics on
  `Exception#class`. The taxonomy (terminal auth/request vs transient
  network/rate-limit) is identical; the full-runtime "not retried" integration
  tests stay at the platform-edge `ModelExecutor`/`RetryableProviderError`
  boundary, which Chronicle already handles.
- **Prompt `_event_summary` reads Chronicle's flat payload shapes.** Upstream
  `object.created`/`relation.created` payloads nest under `object`/`relation`;
  Chronicle stores them flat (`id`, `from_id`, `to_id`, `type`). The view-block
  summary line format is preserved; only the field lookup differs.
  `schema_to_json` diverges by design: Crystal has no Pydantic, so it derives
  the JSON Schema from a `JSON::Serializable` struct's typed fields + enums at
  compile time via the `json-schema` shard (upstream calls a Pydantic model
  class's `model_json_schema()`), and schema blocks render compact sorted JSON
  rather than Python's `indent=2`. LLM data types are plain
  `JSON::Serializable` structs; upstream's `to_dict`/`_parsed_to_jsonable`
  dataclass/dict helpers are replaced by the structs' own `to_json`.

- [x] Error hierarchy + structured format — `Chronicle::ActiveGraphError`
      root with the locked message format (CONTRACT v1.0 #3/#4: the error
      format and the class tree are public contract):
      `<Class>: <summary>` then `What failed:` / `Why:` / `How to fix:`
      (each a two-space-indented continuation block) / `More: <doc_url>`.
      Structured construction takes `what_failed`/`why`/`how_to_fix`/
      `context` and exposes them plus `doc_url` and `structured?`;
      legacy single-argument construction renders the message verbatim.
      The seven category bases (`ConfigurationError`, `RegistrationError`,
      `ExecutionError`, `ReplayError`, `StorageError`, `PatternError`,
      `PackError`) each carry a unique `doc_slug`; `DomainError` keeps the
      `ArgumentError` ancestry so existing rescue sites still work while
      every framework error is transitively an `ActiveGraphError`.
      `ReplayDivergenceError` re-parented under `ReplayError` (reference
      leaf, preserving its legacy message + event_id/expected/actual
      attrs). `internal_bug_fields` produces the uniform context-dict +
      report-URL prose for framework-bug raise sites.
      `MissingOptionalDependency` (Python optional-package helper) is N/A —
      Crystal has no import-time optional dependency surface. Ported from
      activegraph errors.py + test_errors_format.py —
      `spec/chronicle/errors_format_spec.cr`.

## Acceptance Gates

- [x] Same event log → same projection and routing decisions on replay —
      verified determinism: running the same prompt against the same policy
      twice yields byte-identical `routing.decided` receipts (routing is pure:
      smista-style precedence, tie-breaks, privacy, fallback narrowing), and
      `GraphProjection.replay` over a recorded log rebuilds the identical
      object/relation projection. No code change was needed — the property
      already held; the gate is now pinned by spec —
      `spec/chronicle/replay_determinism_spec.cr`.
- [x] Any GraphStore backend passes the full `GraphStoreConformance` suite —
      the reusable contract suite (`spec/chronicle/graph_store_conformance.cr`,
      ported from activegraph.store.graph_conformance) covers every upstream
      method (object/relation/patch round-trips, clear, find_objects,
      find_objects_in_types, find_relations, neighborhood incl. placeholders +
      cycles, match_chain single/one-hop/multi-hop/homomorphic/branching) and
      both backends (`InMemoryGraphStore`, `SQLiteGraphStore`) run it verbatim
      — 44 conformance examples, 0 failures.
- [x] `GraphProjection` write/emit surface matches upstream `Graph`
      (add/remove/attach_store/listeners/sinks). Added `replayed_ids` — every
      event id rebuilt by `GraphProjection.replay` (the `Runtime.load`/`fork`
      seam), distinct from live-emitted events (upstream `Graph.replayed_ids` /
      `_replay_event`, CONTRACT v0.5 #14). `GraphProjection#store` getter not
      needed: the runtime holds the store. Ported from activegraph test_replay —
      `spec/chronicle/replayed_ids_spec.cr`.
- [x] `LogAgent` run loop (`run_goal`/`invoke_*`) emits causally-linked
      `llm.*`/`pattern.*`/`tool.*` events with provenance. `llm.requested` /
      `llm.responded` / `llm.failed` and `tool.requested` / `tool.responded`
      were already causally linked via `caused_by`; added the `pattern.matched`
      lifecycle marker emitted when a pattern-based behavior fires (payload:
      behavior, event_id, matches_count, pattern) — upstream
      `_emit_pattern_matched`. Ported from activegraph test_pattern_subscriptions
      / test_diligence_with_tools — `spec/chronicle/pattern_matched_spec.cr`.
- [x] LLM cache serves recorded responses on matching hashes during replay/fork;
      strict mismatch raises `ReplayDivergenceError`. `Runtime.load(replay_llm_cache:)`
      and strict hash-checked replay were already wired; added `Runtime#fork(replay_llm_cache:)`
      / `replay_tool_cache:` which pre-populate the fork's caches from the
      PARENT's recorded llm.responded / tool.responded events (CONTRACT v0.6
      #8 — a diverging fork that regenerates an identical prompt hits the
      cache; a divergent prompt falls through), plus a `Runtime#llm_cache`
      getter. Ported from activegraph runtime.py fork cache wiring —
      `spec/chronicle/llm_cache_wiring_spec.cr`.
- [x] `frame_id` preserved on events and visible in log inspect — the event
      envelope already carried `frame_id` through `canonical_json` and the
      codec round-trip (`frames_spec.cr`); `Runtime#export_trace` already
      emitted it via `canonical_json`. Gap closed: the CLI `log inspect`
      renderer now prints a `frame:` line for events that carry a frame id.
      Ported from activegraph test_event.py to_dict round-trip + trace printer
      — `spec/chronicle/cli_spec.cr`, `spec/chronicle/frames_spec.cr`.
- [x] `check_source_parity.sh` and `check_test_parity.sh` pass; `check_port_inventory.sh`
      reports no untracked symbols once the ledger is expanded. Generated
      `plans/inventory/python_source_parity.tsv` (1210 API items) and
      `python_test_parity.tsv` (42 tests) via the skill's ensure_parity_plan;
      expanded `python_port_inventory.tsv` to the full discovered-id format
      (all 1210 source symbols tracked, 62 marked `ported` with Crystal spec
      refs). All three checks pass. `.metadata.json` discovery artifacts are
      gitignored (machine-local paths).
