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
The feature-size roadmap (S / M / L, below) tracks what remains and the
concrete next-up order. **S and M core are complete and committed** (the
event-sourcing core, runtime execution surface, LLM layer, tools, packs,
sinks/observability, frames, CLI/trace, and both GraphStore backends); the
remaining S/M batch targets the provider/platform seams (embedding, native
structured output, CLI quickstart) and the L batch targets external backends
(Postgres, sandbox, observability backends, retention).

[cross-language-crystal-parity]: /Users/dominic/.agents/skills/cross-language-crystal-parity/SKILL.md

---

## Feature-size roadmap (S / M / L)

The phases below are sized so each feature is branch-sized and
user-visible (per the cross-language-crystal-parity skill's feature slicing
rules). `[x]` = green and committed; `[ ]` = pending; `[-]` = intentionally
deferred (documented in the Intentional Divergence / deferred rows of the
phases).

### S — small (helpers, value objects, narrow surfaces)

- [x] `RuntimeReason` helpers — `now_iso`/`monotonic` (593), `open_sqlite_store`
      (583), `budget_reason` (568), `resolve_event_path` (559),
      `promote_data_diff` (550), `maybe_object_id` (449), `first_goal` (457),
      `is_lifecycle` (461), `validate_embedding_vectors` (539),
      `most_recent_run_id` (483), `recorded_wall_stop` (490),
      `non_replayable_llm_attempt_event_ids` (499), `direct_embedding_event_ids`
      (509), `resolve_and_validate_llm_models` (519), `doc_url_for_reason` (420).
- [x] Structured error leaves — `ActiveGraphError` hierarchy + format (1123),
      `ReplayDivergenceError` builders (1144), per-reason prose (1166),
      PR-E registration/execution leaves (1184).
- [x] Wire helpers — `Chronicle::Wire` tool-name sanitize/restore + provider
      exception taxonomy (726).
- [x] `Runtime#status` value object + `RuntimeStatus`/`BehaviorInfo`/`EventSummary`
      (804).
- [x] `SinkConfig` + constructor sink normalization (472).
- [x] `Runtime#errors` projection — `BehaviorFailure` value struct (406).
- [x] LLM retry helpers (pure) — `transient_llm_reason?` / `llm_retry_delay_seconds`
      (429).
- [x] `Runtime#print_graph` — `Runtime#print_graph` (runtime.py:3137) renders
      the attached graph in upstream's console format — `graph:` header,
      `objects (N):` rows as `<id>" <title-or-text-label>" (<status>)`, and
      `relations (N):` rows as `<source> --<type>--> <target>`. Sans-IO: the
      text is returned as a String; the caller prints it (no console I/O in
      the core). Empty title/text/status fields are omitted like upstream.
      — `spec/chronicle/print_graph_spec.cr`.
- [x] `Runtime#save_state` — `Runtime#save_state(path)` (runtime.py:3152,
      CONTRACT v0.5 #5): with a SQLite store attached it flushes and returns
      the store path (a mismatched `path=` raises
      `InvalidRuntimeConfiguration` — save targets are pinned at construction);
      without a durable store it late-binds a SQLite store at `path=` and
      appends every in-memory event (returning the path), and `save_state()`
      with no path and no durable store raises `InvalidRuntimeConfiguration`.
      The late-bound store records the run's goal and current frame_id.
      Ported from activegraph tests/test_persistence.py
      (`test_late_bound_save_writes_in_memory_events_to_sqlite`,
      `test_save_state_without_store_requires_path`,
      `test_save_state_path_must_match_attached_store`,
      `test_save_then_load_produces_identical_graph`) —
      `spec/chronicle/save_state_spec.cr`.
- [x] `EventQueue` — `runtime/queue.py` value object (bounded FIFO used by
      upstream dispatch, CONTRACT #10: no priority, no async):
      `Chronicle::EventQueue` (push / pop / size / empty?, FIFO ordering).
      Chronicle's dispatch drains directly from the store, so this is a
      parity shape, not a runtime gap — the value object is available for
      tests and tools rather than wired into dispatch —
      `spec/chronicle/event_queue_spec.cr`.
- [x] `ToolContext` — `tools/context.py` value object (CONTRACT v0.7 #5):
      `Chronicle::ToolContext` (behavior_name, event_id, frame_id,
      idempotency_key, timeout_seconds, external_io_mode defaulting to
      `forbid`). The runtime threads one into EVERY tool invocation:
      `invoke_tool` supplies `external_io_mode=runtime_recorded` (upstream
      `_invoke_tool`) and the LLM-behavior tool loop stamps
      behavior_name/event_id/frame_id plus a fresh idempotency_key, so
      mode-gated tools (web_fetch) fail closed unless an explicit
      `live_unrecorded` bypass is configured. `@[Tool]` methods may now
      declare an optional `(args, ctx)` parameter to read the context
      (the DSL raises for any other parameter shape). Ported from
      activegraph tools/context.py + tests/test_tools.py ToolContext
      construction + runtime `_invoke_tool` wiring —
      `spec/chronicle/tool_context_spec.cr`. Divergence: the per-tool logger
      is platform-edge (Crystal has no stdlib logging context), and
      `timeout_seconds` defaults to 30.0 (the Crystal `@[Tool]` decorator has
      no timeout field yet).

### M — medium (behavioral surfaces spanning one module)

- [x] LLM-behavior tool loop (1202) — declared-tool invoke + re-call,
      `max_tool_turns` exhaustion, `max_tool_calls` budget gate, unknown-tool
      refusal, missing-tool-at-registration, bad-tool-input schema validation,
      `llm.network_error` fold.
- [x] LLM cache — wiring into replay/fork (651), tool-call round-trip (1286).
- [x] Tool input-schema validation — `validate_input!` (1229).
- [x] `ctx.propose_object` + approval materialization (929).
- [x] `activate_after` delayed-queue scheduling (352).
- [x] `run_quantum` cooperative drain (614).
- [x] Sink conformance mixin + raising-sibling isolation (850).
- [x] Same-target LLM retry loop — upstream `_invoke_llm_body` retries a
      transient provider failure in place before emitting the terminal
      `behavior.failed`. `Runtime` now takes `llm_retry_max_attempts` /
      `llm_retry_initial_delay_seconds` / `llm_retry_max_delay_seconds`
      (upstream defaults 3 / 0.5 / 8.0, normalized like upstream), threaded
      through the constructor, `fork`, and both `load` overloads. The
      LLM-behavior path's `execute_model_request` retries a transient failure
      on the SAME target up to `max_attempts` (cache consulted once per turn,
      not per attempt — upstream `max_attempts = 1 if cached is not None`);
      each retried `llm.requested` carries `attempt_index` / `max_attempts` /
      `retry_of` (the first attempt's request id), and the backoff sleeps
      `llm_retry_delay_seconds` (honoring a provider-supplied
      `retry_after_seconds`). A transient failure that exhausts the budget
      emits `behavior.failed` with `attempts` / `max_attempts` /
      `retry_exhausted` extras (upstream `_emit_behavior_failed`); a terminal
      reason (e.g. `llm.parse_error`, `llm.auth_error`) is never retried. The
      shared agent path keeps `retry_max_attempts=1` so routing-fallback
      selection is unchanged. Divergence: Chronicle records each failed
      attempt as a separate `llm.failed` event (the `_emit_llm_error_response`
      `llm.responded` error-shape is the next pending item). Ported from
      activegraph tests/test_llm_failure.py
      `test_transient_llm_network_error_retries_before_handler_runs` /
      `test_transient_llm_network_error_exhausts_after_max_attempts` —
      `spec/chronicle/llm_retry_loop_spec.cr`.
- [x] Structured-output schema typing — `@[LLMBehavior(output_schema: SomeStruct)]`
      where `SomeStruct` is a `JSON::Serializable` struct. The DSL generates a
      handler that runs `Chronicle::StructuredOutput.parse` (upstream
      `llm/parsing.py::parse_structured_response`, CONTRACT v1.0.1 #5) over the
      raw provider text — verbatim JSON, else a fenced ```json block, else the
      first balanced `{..}`/`[..]` span — and hands the handler the TYPED value
      instead of the raw string (closes the (1081) divergence). Failures map to
      `LLMBehaviorError` (folded to `behavior.failed`): `llm.parse_error` when
      no JSON is recoverable, `llm.schema_violation` when the schema rejects
      it, each carrying `raw_text` / `schema` / `validation_errors` payload
      extras merged into the `behavior.failed` event (upstream
      `_emit_behavior_failed`'s `extras=e.payload_extras`). `PackBehavior`
      carries `output_schema_name` / `output_schema_json` (derived via
      `Prompt.schema_to_json`), and the LLM-behavior turn payload includes them
      so a typed request hashes distinctly from an untyped one (upstream
      `_hash_turn_prompt` includes output_schema). Divergence: upstream
      validates the schema at decoration time; Crystal enforces
      `JSON::Serializable` at compile time. Native structured output
      (`_resolve_structured_output_mode`, llm/native.py) stays deferred.
      Ported from activegraph tests/test_llm_behavior.py
      `test_llm_behavior_invokes_handler_with_parsed_output`,
      tests/test_llm_anthropic.py `test_complete_extracts_json_from_fenced_block`
      / `test_complete_raises_parse_error_when_no_json` /
      `test_complete_raises_schema_violation_when_json_valid_but_wrong_shape`,
      tests/test_llm_failure.py `test_schema_violation_becomes_behavior_failed`
      — `spec/chronicle/structured_output_spec.cr`,
      `spec/chronicle/llm_output_schema_spec.cr`.
- [x] `llm.responded` error-shape parity — `record_llm_failed` now emits the
      upstream `_emit_llm_error_response` error shape on the failed-attempt
      event: a nested `error` object `{reason, message, **extras}` (structured
      LLMBehaviorError/ToolError reasons + payload_extras; generic exceptions
      fold to `llm.network_error`), `retryable` (using the transient-reason /
      generic fold, matching upstream), `attempt_index` / `max_attempts`,
      `latency_seconds`, `cost_usd: "0"`, `cache_hit: false`, plus `behavior` /
      `prompt_hash` / `model`, `caused_by` the request. The retry loop threads
      attempt_index/max_attempts/latency and the behavior name into the
      recorder. Divergences (documented): the event name stays `llm.failed`
      (upstream folds errors into `llm.responded`), and the generic-exception
      `message` is redacted to the exception class name — provider exception
      text (which can carry credentials / raw client identifiers) never enters
      the event log. Ported from activegraph runtime.py
      `_emit_llm_error_response` + tests/test_llm_failure.py —
      `spec/chronicle/llm_error_shape_spec.cr`.

### S — next batch (small: renderers, narrow runtime surfaces)

- [x] CLI renderers — `cli/renderers.py` (97-line module):
      `Chronicle::Renderers` — `memo_company_name` (memo `company_id` →
      company name, with `<unknown>` / raw-id fallbacks) and
      `memo_section_lines` (the quickstart/operator memo section: summary /
      key claims with evidence ids / open contradictions or their explicit
      note / risks with related-claim + severity clauses), plus the private
      `wrap_indented` word-wraper. Sans-IO: the renderers return lines
      (`Array(String)`); the CLI / caller writes them. Divergence: upstream's
      `print_memo_section` writes to a stream and renders contradiction dicts
      via Python repr; Chronicle returns lines and renders contradictions as
      compact JSON. Ported from activegraph cli/renderers.py —
      `spec/chronicle/cli_renderers_spec.cr`.
- [x] Scheduler (covered) — `runtime/scheduler.py` (206-line module) is the
      event-count scheduler for `activate_after` (CONTRACT v0.7 #13) and is
      fully ported: `Chronicle::Packs.parse_activate_after` (int / "N" /
      "N event(s)"; rejects bool, wall-clock units, garbage, zero/negative),
      `InvalidActivateAfter`, `ScheduledEntry`, and `DelayedQueue`
      (`push`/`pop_due`/`empty?`), wired into `Runtime#schedule_delayed` /
      `_fire_due_delayed`. There is NO upstream wall-clock `schedule`/`loop`
      API to port: the module deliberately keeps wall-clock OUT (the docstring
      and `InvalidActivateAfter` reject seconds/minutes/hours with a CONTRACT
      v0.7 #13 pointer; the v1+ escape hatch is `runtime.tick()` + injected
      `timer.fired` events, not a ported surface). The earlier "schedule/loop
      wall-clock extension is not ported" note was a misread of that decision.
      — `spec/chronicle/activate_after_spec.cr`.

### M — next batch (medium: provider/platform seams spanning one module)

- [x] Embedding provider protocol + cache — `llm/embedding.py` +
      `llm/embedding_cache.py` (CONTRACT v1.8 #6): `Chronicle::EmbeddingProvider`
      (default_model + `embed(texts, model)`), the deterministic
      `HashEmbeddingProvider` test double (SHA-256 bucket-count L2-normalized
      vectors; rejects `dimensions < 1`) which ALSO implements Crig's
      `EmbeddingModel` seam (`max_documents`/`ndims`/`embed_texts`) so it
      plugs into Crig vector stores, and `CrigEmbeddingProvider(M)` adapting
      any Crig embedding model to the protocol. `Chronicle::EmbeddingCache`
      (content-keyed by SHA-256 of sorted-key `{model, texts}`; defensive
      copies; `from_events` harvest skipping error/malformed/count-mismatch
      responses). `Runtime#embed` records a content-keyed
      `embedding.requested`/`embedding.responded` pair (never the input text),
      serves recorded returns from the cache on load/fork with zero provider
      contact, records provider errors without caching, and strict replay
      rejects input-hash drift with `embedding_hash_mismatch` (offline gate —
      strict replay never contacts the provider). The provider/cache thread
      through the constructor, `fork`, and both `load` overloads (inherit
      parent provider on fork). `ctx.embed` threads the behavior + triggering
      event through the recorded path (`RuntimeContextRequiredError` when
      unbound) — this also unblocks the deferred `ctx.embed` noted in the
      `propose_object` row. Ported from activegraph tests/test_embedding_provider.py +
      tests/test_embedding_replay.py — `spec/chronicle/embedding_spec.cr`,
      `spec/chronicle/embedding_cache_spec.cr`,
      `spec/chronicle/embedding_runtime_spec.cr`.
- [x] Native structured output — `llm/native.py` +
      `runtime.py::_resolve_structured_output_mode` (CONTRACT v1.3 #1):
      `Chronicle::Native` ports the schema pre-flight — `native_schema_compatible`
      (root object schema, allowlisted keywords only, every object property
      required, `additionalProperties` already false, `$ref` targets internal
      and non-recursive) and `inject_additional_properties_false` (deep copy +
      `additionalProperties: false` on every object node — the one permitted
      pure narrowing) — plus the pure `resolve_structured_output_mode(flag,
      model, capability, schema)` resolver. The runtime takes
      `native_structured_output:` (opt-in) + `native_capability:` (injectable
      provider-capability predicate); the memoized per-behavior mode rides
      every `llm.requested` payload (`structured_output_mode` field) and
      contributes to the prompt hash ONLY when native — a mode flip changes
      the cache key, so prompt-mode payloads stay byte-identical to pre-v1.3
      and a record-vs-replay mode drift surfaces as a cache miss. Divergence:
      the provider-wire `output_config`/`response_format` forwarding on native
      calls stays at the provider-adapter boundary (the `LLMProvider#complete`
      `structured_output_mode:` seam carries it; the Crig executor has no
      schema field), and the native system prompt does not drop a schema block
      (the Chronicle prompt-mode path never embeds one). Ported from activegraph
      tests/test_llm_native_structured_output.py #8 pre-flight +
      `test_native_mode_end_to_end_and_requested_payload` /
      `test_flag_on_but_no_capability_resolves_prompt` /
      `test_flag_on_but_schema_outside_subset_resolves_prompt` /
      `test_prompt_mode_hashable_has_no_mode_key` —
      `spec/chronicle/native_structured_output_spec.cr`,
      `spec/chronicle/native_mode_runtime_spec.cr`.
- [x] Provider adapters (Anthropic/OpenAI) — **covered, no adapter port
      needed**: the router already executes every provider through Crig via the
      `ModelExecutor`/`ProviderRegistry` seam + the Crig provider factories
      (`AnthropicProviderFactory`, `OpenAIProviderFactory`,
      `OpenAICompatibleProviderFactory`, `DeepSeekProviderFactory`,
      `OllamaProviderFactory`, `GeminiProviderFactory`) — adding a provider is
      a `CrigProviderFactory`, not an `LLMProvider` implementation. The
      upstream `llm/anthropic.py` / `llm/openai.py` HTTP providers (and the
      `Wire` tool-name round-trip / provider-exception taxonomy they consume)
      map onto Crig clients + the already-ported `Wire` helpers. Recording and
      replay are event-log based: every `llm.requested`/`llm.responded` event
      carries `provider` + `model` (from the routing target) + prompt hash, and
      `LLMCache.from_events` + `Runtime.load/fork(replay_llm_cache: true)`
      replay recorded responses with zero provider contact — so the provider
      used is captured automatically, with no separate adapter. The
      `LLMProvider` protocol (`RecordedLLMProvider` / `RecordingLLMProvider`)
      stays a standalone fixture seam, not wired into the runtime execution
      path. Marked `intentional_divergence` in the ledger.
- [x] Diligence reference pack — `packs/diligence/*`: a runnable Crystal port
      of the upstream reference pack on the pack DSL —
      `Chronicle::Packs::Diligence` with `@[ObjectType]` schemas (company,
      question, claim, evidence, contradiction, memo), `@[RelationType]`
      rules (addresses, supports, contradicts), typed settings
      (`auto_approve_memos` / `max_questions` / `max_claims_per_document` /
      `confidence_threshold_for_review`), plain + `@[LLMBehavior]` +
      pattern-subscription behaviors (company_planner, question_generator,
      claim_extractor with a pack-scoped tool, evidence_linker safety net,
      contradiction_detector via the `(c1:claim)-[r:contradicts]->(c2:claim)
      WHERE c1.confidence > 0.7 ...` pattern, memo_synthesizer), and the
      `memo_approval` policy (propose_object / approve_pack). Runs the full
      flow end-to-end against a scripted Crig provider: goal → company →
      questions → claims + evidence + contradicts edge → contradiction (pattern)
      → memo (materialized under auto_approve_memos, proposed + approve_pack
      otherwise). Not a line-for-line port: the recorded 3-company fixtures
      and `risk_identifier` are out of scope (fixtures are scripted in the
      spec; a production user swaps real tool bodies). Ported from activegraph
      packs/diligence/* — `spec/chronicle/diligence_pack_spec.cr`.
- [ ] CLI quickstart — `cli/quickstart.py` (477): the `chronicle-cli
      quickstart` demo surface and its result renderers (builds on the CLI
      renderers S item).

### L — next batch (large: external backends, deferred)

- [ ] Postgres event store — `store/postgres.py` (needs `pg` shard + live
      server; the `EventStore` protocol is the path for adding it).
- [ ] Postgres / FalkorDB GraphStore pushdown — `store/postgres.py`,
      `store/falkordb.py` (any backend passing the conformance suite is
      interchangeable).
- [ ] Retention / compaction — `store/retention.py` (368): offline snapshot
      sidecar + archive-tier compaction.
- [ ] Sandbox executor/conformance — `sandbox/*` (`_child`, `executor`,
      `conformance`).
- [ ] Prometheus / OTel / migration — `observability/prometheus.py`,
      `observability/otel.py`, `observability/migration.py` (external
      backends; the `Metrics` protocol + `Logging` schema are ported).

### Next up (concrete plan order)

The S and M core batches above are complete; this is the ordered plan for the
remaining S/M batch, then the deferred L batch:

1. `[x]` CLI renderers — `Chronicle::Renderers` memo renderer lines (S);
   `cli/quickstart.py` demo surface stays M-pending on top of it.
2. `[x]` Scheduler — covered: `runtime/scheduler.py` is the event-count
   `activate_after` scheduler (fully ported in `Chronicle::Packs`); there is
   no upstream wall-clock `schedule`/`loop` API (wall-clock is out of scope
   per CONTRACT v0.7 #13).
3. `[x]` Embedding provider protocol + cache — `llm/embedding.py` +
   `llm/embedding_cache.py` + `Runtime#embed` / `ctx.embed` (M); uses Crig's
   `EmbeddingModel` seam (`CrigEmbeddingProvider` + the `HashEmbeddingProvider`
   shim); unblocks the diligence pack.
4. `[x]` Native structured output mode — `llm/native.py` +
   `_resolve_structured_output_mode` (M); the runtime resolves + carries the
   mode and hashes it when native; provider-wire forwarding stays at the
   adapter boundary.
5. `[x]` Provider adapters (Anthropic/OpenAI) — covered, no port needed: the
   router executes through Crig via `ModelExecutor`/`ProviderRegistry` + the
   provider factories; the `LLMProvider` protocol stays the standalone
   recorded-fixture seam (not wired into the runtime path). Ledger rows marked
   `intentional_divergence`.
6. `[x]` Diligence reference pack — `Chronicle::Packs::Diligence` runnable
   reference on the pack DSL (object/relation types, settings, plain/LLM/
   pattern behaviors, tool, policy); spec drives the full flow with a
   scripted provider.
7. `[-]` L deferred (ordered): Postgres event store → Postgres/FalkorDB
   GraphStore pushdown → retention/compaction → sandbox conformance →
   Prometheus/OTel/migration.

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
- [x] Replay — `Chronicle::ReplayEngine` (strict/permissive). Strict mode
      ports `_verify_replay`'s stream comparison (runtime.py #L4180-L4368):
      both sides drop lifecycle events and promote blocks; the recorded side
      additionally drops `non_replayable_llm_attempt_event_ids` and
      `direct_embedding_event_ids`. Comparison is over `(id, type)` only —
      payload differences at matching positions do NOT diverge (hash checks
      live in the cache wiring). The first type mismatch is pinned at the
      recorded event id with `expected`/`actual`; a length mismatch pins the
      first unpaired position with `"<no recorded event>"` on the unrecorded
      side — `spec/chronicle/replay_spec.cr`,
      `spec/chronicle/replay_stream_spec.cr`
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
- [x] Multi-dimensional `Budget` — `Chronicle::Budget` (the full port of
      `runtime/budget.py`): `KNOWN_LIMITS` (max_events, max_behavior_calls,
      max_llm_calls, max_tool_calls, max_patches, max_depth, max_seconds,
      max_cost_usd; omitted dimensions unlimited), `consume` /
      `remaining` / `exhausted_by` / `mark_exhausted` / `start`
      (`read_wall_clock:` for clock-free strict replay) for counter + wall
      dimensions, and the Decimal-cost dimension surfaced as Float64 + String
      mirror (`has_cost_limit` / `add_cost` / `cost_remaining` /
      `cost_remaining_amount` / `cost_used`). `snapshot` returns the existing
      `Chronicle::BudgetSnapshot` value. Wired into `Runtime`: the old nested
      `Runtime::Budget` struct is now an alias to `Chronicle::Budget` (the
      `max_events:` convenience constructor preserves pre-port call sites;
      the runtime default is 1000 max_events), `budget_remaining` /
      `start_budget` read the max_events dimension, `budget_exhausted?` syncs
      the used counter from the store and consults `remaining`, the
      `runtime.budget_exhausted` payload is the full snapshot, and
      `Runtime#status` reports `@budget.snapshot`. Divergence: `_as_decimal`
      is N/A — cost accumulates as Float64 (upstream Decimal; CONTRACT v0.6
      #9 intent preserved for realistic magnitudes) and is mirrored as a
      String. Ported from activegraph runtime/budget.py —
      `spec/chronicle/budget_spec.cr`.
- [x] Tool lookup — `get_tool(name)` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Approvals — `pending_approvals` / `approve` / `add_pending_approval` —
      `runtime/runtime.py` — `spec/chronicle/runtime_phase3_spec.cr`
- [x] Authority — `authority_ceiling` / `set_authority_ceiling` /
      `evaluate_capability_authority` — `runtime/authority.py` —
      `spec/chronicle/runtime_phase3_spec.cr`. Upgraded to the CONTRACT v1.9
      action-class path: `Chronicle::Authority` (the pure decision module
      ported from `runtime/authority.py`) with the closed class set
      `R0|R1|R2|R3|R4`, closed ceilings `none|R0|R1|R2`, `AuthorityDecision`,
      `validate_ceiling`, and `evaluate_action_authority` (fixed evaluation
      order: missing/invalid class fails closed to approval, R4 →
      governance_gate always, R3 → require_approval always, R0–R2
      auto-approve iff at or below the effective ceiling — the stricter of
      the instance ceiling and a per-capability ceiling that can only lower).
      `Runtime#authority_ceiling` is log-backed (last accepted
      `authority.ceiling_changed`, default `"none"`); `set_authority_ceiling`
      validates (R3/R4/garbage rejected loudly before emission) and emits
      `authority.ceiling_changed` with mandatory actor/reason, returning the
      event id; `evaluate_capability_authority` emits an
      `authority.decision` audit event and returns the decision carrying the
      accepted event id; `authority.*` events never schedule behaviors
      (suppressed in dispatch). Ceilings survive load/fork. The legacy
      read < write < admin < root scale is replaced. `spec/chronicle/authority_spec.cr`.
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
      object.updated does). There is no upstream wall-clock `schedule`/`loop`
      extension to port — `runtime/scheduler.py` is event-count only
      (CONTRACT v0.7 #13), and the v1+ escape hatch (`runtime.tick()` +
      injected `timer.fired` events) is not a ported surface.
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
- [x] `direct_embedding_event_ids` —
      `Chronicle::RuntimeReason.direct_embedding_event_ids(events)` collects
      operator-invoked embedding pair ids that strict replay cannot
      re-derive: an `embedding.requested` with no `caused_by` (an external
      seed action, not behavior output) plus its `embedding.responded`
      partner, excluded from the compared streams while the recorded return
      stays available to the cache on load (upstream
      `_direct_embedding_event_ids`). Behavior-derived calls (request with a
      `caused_by`) are excluded. Ported from activegraph runtime/runtime.py —
      `spec/chronicle/direct_embedding_ids_spec.cr`.
- [x] `resolve_and_validate_llm_models` — CONTRACT v1.0.2 #1: (a)
      `Chronicle::RuntimeReason.resolve_llm_model(model, provider)` returns
      the behavior's pinned model or the configured provider's
      `default_model` when none is pinned (the protocol's own default is the
      v1.0.1 fallback `"claude-sonnet-4-5"`, so pre-v1.0.2 call sites keep
      working byte-identically); (b)
      `Chronicle::RuntimeReason.validate_and_resolve_llm_model` raises
      `Chronicle::InvalidRuntimeConfiguration` before the first network call
      when a pinned model the provider does not recognize is claimed by a
      DIFFERENT shipped provider family, delegating to
      `Chronicle::RuntimeReason.which_shipped_provider_claims`
      (`Chronicle::ShippedProviderFamily` with `exclude=type(provider)` via
      `provider_class`; permissive default — names no shipped family claims
      pass through silently). Divergence: upstream stamps `behavior.model` in
      place via mutable Python behaviors; Chronicle behaviors are immutable
      so resolution is computed on demand. Shipped Anthropic/OpenAI providers
      are deferred; the family list is an injectable seam fully exercised by
      tests. Ported from activegraph runtime/runtime.py
      `_resolve_and_validate_llm_models` + runtime/_live.py `_validate_one` /
      `_which_shipped_provider_claims` — `spec/chronicle/resolve_llm_model_spec.cr`.
- [x] `validate_embedding_vectors` —
      `Chronicle::RuntimeReason.validate_embedding_vectors(texts, vectors)`
      validates and normalizes a provider's batch embedding response
      (upstream `_validate_embedding_vectors`): the vector count must match
      the text batch, every vector must be a list with uniform dimensions,
      and every component must be a finite number. Raises `ArgumentError`
      (the Crystal analogue of upstream `ValueError`) with the upstream
      message shapes; the runtime records the error rather than caching it.
      Divergence: the non-list type name renders as the Crystal class name
      (`Hash`) where upstream reports the Python type. Ported from activegraph
      runtime/runtime.py — `spec/chronicle/validate_embedding_vectors_spec.cr`.
- [x] `promote_data_diff` —
      `Chronicle::RuntimeReason.promote_data_diff(old, new)` builds the
      per-field `{old, new}` diff for a promote replace-patch (upstream
      `_promote_data_diff`): sorted keys, dropped fields render as
      `new: null`, added fields as `old: null`, and equality is numeric-aware
      (3 == 3.0 is unchanged). Wired into the promote apply path so each
      `patch.applied` replace-patch carries the `diff` field like any other
      patch, matching upstream's emit at runtime.py. Ported from activegraph
      runtime/runtime.py — `spec/chronicle/promote_data_diff_spec.cr`.
- [x] `resolve_event_path` —
      `Chronicle::RuntimeReason.resolve_event_path(expr, event)` resolves a
      dotted `event.<path>` expression against an Event, used by view specs'
      `around=` anchors (upstream `_resolve_event_path` in
      runtime/view_builder.py): walks `event.payload.<...>` through the parsed
      JSON hash; other first segments read event attributes; nil when the
      expression doesn't start with `event`, is empty, or any segment is
      missing/null. Ported from activegraph runtime/view_builder.py —
      `spec/chronicle/resolve_event_path_spec.cr`.
 - [x] `budget_reason` —
      `Chronicle::RuntimeReason.budget_reason(name : String?)` maps a budget
      dimension name to the `reason` code carried by `behavior.failed` /
      `llm.failed` when a dimension exhausts (upstream `_budget_reason`):
      `max_tool_calls` → `budget.tool_calls_exhausted`, `max_cost_usd` →
      `budget.cost_exhausted`, `max_llm_calls` →
      `budget.llm_calls_exhausted` (the explicit `_BUDGET_REASON_MAP`); any
      other dimension derives `budget.<max_-stripped-name>_exhausted`
      (`max_events` → `budget.events_exhausted`, `max_seconds` →
      `budget.seconds_exhausted`, ...); nil renders the generic
      `budget.exhausted`. The `max_`-stripping is a no-op for names without
      the prefix (`custom` → `budget.custom_exhausted`), matching Python's
      `removeprefix`. Every `KNOWN_LIMITS` dimension is covered. Ported from
      activegraph runtime/runtime.py `_budget_reason` + test_reason_codes_docs.py
      — `spec/chronicle/budget_reason_spec.cr`.
 - [x] `open_sqlite_store` —
      `Chronicle::RuntimeReason.open_sqlite_store(path_or_url, run_id)` opens
      a SQLite store by bare path (v0.5-v0.7 sugar) or connection URL (v0.8,
      upstream `_open_sqlite_store`). A bare path is treated as a SQLite path
      directly; anything containing `://` is parsed with `parse_store_url`
      and dispatched by scheme (`sqlite` → its resolved `sqlite_path`).
      A postgres URL raises `IncompatibleRuntimeState` — the Postgres
      backend is deferred (the `EventStore` protocol is the path for adding
      it). Ported from activegraph runtime/runtime.py `_open_sqlite_store` +
      store/url.py `open_store` — `spec/chronicle/open_sqlite_store_spec.cr`.
 - [x] `now_iso` / `monotonic` —
      `Chronicle::RuntimeReason.now_iso` (UTC ISO-8601 second-precision
      timestamp with trailing `Z`, upstream `_now_iso`) is now the single
      source of truth for recorded timestamps — `ToolRecorded.now_iso` and
      `RecordingLLMProvider#now_iso` delegate to it — and
      `Chronicle::RuntimeReason.monotonic` returns the monotonic clock in
      fractional seconds (upstream `_monotonic`), measured as elapsed
      seconds since a module-load `Time.instant` base reading (Crystal's
      `Time.instant` is opaque, so only differences are meaningful; the
      deprecated `Time.monotonic` is avoided). Ported from activegraph
      runtime/runtime.py `_now_iso` + `_monotonic` —
      `spec/chronicle/now_iso_spec.cr`.
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
- [-] Provider adapters (Anthropic/OpenAI/native structured output) — covered
      by the Crig seam: the router executes through `ModelExecutor`/
      `ProviderRegistry` + the Crig provider factories (`AnthropicProviderFactory`,
      `OpenAIProviderFactory`, ...), and native-mode resolution is ported
      (`Chronicle::Native`). The upstream HTTP providers are not ported as
      classes — the `LLMProvider` protocol stays the standalone recorded-fixture
      seam. `llm/native.py` pre-flight/resolution ported; the raw
      request/response helpers stay Crig's job.
- [x] Wire protocol (request/response types, canonical serialization,
      `prompt_hash`) — `llm.requested` events now carry `prompt_hash` (the
      canonical prompt digest, upstream `turn_hash`) alongside `request_hash`
      so trace consumers can key on the prompt identity like upstream does.
      `EffectRequest`/`ModelEffectRequest` remain structs carrying the
      canonical `content_hash`. Ported from activegraph runtime.py
      requested_payload — `spec/chronicle/llm_cache_wiring_spec.cr`.
      `llm/types.py` provider types and `llm/native.py` stay deferred.
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
- [x] Embedding — `llm/embedding.py`, `llm/embedding_cache.py` ported:
      `EmbeddingProvider` protocol + `HashEmbeddingProvider` (also a Crig
      `EmbeddingModel` shim) + `CrigEmbeddingProvider(M)` adapter +
      `EmbeddingCache` + `Runtime#embed` / `ctx.embed` (CONTRACT v1.8 #6).
      Real network embedding providers (OpenAI embeddings, Voyage, local
      sentence-transformers) remain pack/application territory per upstream.
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
- [x] Diligence reference pack — `Chronicle::Packs::Diligence` runnable
      reference on the pack DSL (see the roadmap M-batch row); the recorded
      3-company fixtures and `risk_identifier` stay out of scope (fixtures
      scripted in the spec).
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
      approve-materialization of gated object types. `ctx.embed` uses the
      same runtime-backref pattern and now threads through the recorded
      embedding path. Ported
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
- [x] CONTRACT #18 trace line rendering — `Chronicle::Trace.format_event(event)`
      renders each event type as a CONTRACT #18 line: the `[tag]` column is
      left-aligned and padded to `TAG_COL = 26` (`format_tag`), with formatters
      for goal/object/relation/patch/promote/behavior/llm/tool/pattern/runtime/
      pack event types and a `[event.emitted]` fallback. Divergence: Chronicle
      stores flat payloads (object.created carries `id`/`type`/`data` at top
      level; relation.created carries `from_id`/`to_id`; llm.requested carries
      `request_hash`/`prompt_hash`/`provider`/`model`/`cache_hit` — no
      `behavior`/`tokens`/`budget` fields), so the formatters read Chronicle's
      flat shapes rather than upstream's nested `object`/`relation` dicts and
      elide fields Chronicle does not record. `_fmt_llm_requested` reads
      Chronicle's actual payload fields when present and omits `prompt_normalized`
      handling (rollup stays a faithful no-op). Ported from activegraph
      trace/printer.py `format_event` + formatters —
      `spec/chronicle/trace_lines_spec.cr`.
- [x] Trace facade `lines` rendering — `Chronicle::TraceFacade#lines(replayed_ids)`
      walks the event log in order and renders CONTRACT #18 lines, with replay
      events rendered as `[replay.event] <id> <type> <summary>` (CONTRACT v0.5
      #22) followed by a single `[replay.complete] N events replayed, graph
      reconstructed` + `[runtime.idle] ready to resume` boundary, plus the
      v0.9.1 `prompt_normalized` `[trace.flags]` rollup (a no-op for
      Chronicle's prompt_hash payloads, retained for parity). Chronicle's
      facade wraps the `EventStore` (upstream wraps the Graph), so `lines`
      takes `replayed_ids` explicitly. Divergence: upstream `Trace.print` /
      `Trace.export` I/O renderers stay at the CLI boundary — core `trace.cr`
      is I/O-free (core_io_safety_spec); the CLI `trace` subcommand still
      renders the causal chain. Ported from activegraph trace/printer.py
      `Trace.lines` + `_fmt_replay*` — `spec/chronicle/trace_lines_method_spec.cr`.
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
- **Pack tools accept `args` plus an optional `ctx`** (no `settings` parameter
  yet); the DSL raises at compile time if a `@[Tool]` method declares any
  other parameter. A tool body may declare `(args, ctx : Chronicle::ToolContext)`
  to read the triggering behavior/event/frame, idempotency key, and the
  `external_io_mode` threaded by runtime dispatch.
- **Object/relation schemas use `JSON::Serializable` + a DSL-generated
  validator**; Pydantic `Field(ge=...)`-style constraint annotations aren't
  supported (type/requiredness checks are).
- **Discovery uses an explicit `Registry`** (the DSL registers the pack when
  its module is required) instead of Python entry points; `discover()` caches
  per process and `register`/`clear_discovery_cache` invalidate.
- **`_pack_local` is enforced at compile time** (only the DSL builds pack
  objects) rather than via a runtime flag on every `Behavior`/`Tool`.
- **LLM behavior execution dispatch runs through the LLM effect pipeline**;
  `@[LLMBehavior(output_schema:)` handlers receive a typed
  `JSON::Serializable` value (parsed by `Chronicle::StructuredOutput.parse`,
  the `parse_structured_response` port); untyped handlers receive the raw
  output string. Native structured-output mode is resolved and carried
  (`Chronicle::Native` pre-flight + `Runtime(native_structured_output:)` +
  `native_capability:`), but the provider-wire `output_config` /
  `response_format` forwarding on native calls stays at the provider-adapter
  boundary — the `LLMProvider#complete(structured_output_mode:)` seam carries
  the mode, and the Crig executor has no schema field — and the output-schema
  reminder is folded into the turn-payload hash rather than the prompt text.
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
- **Provider exception text never enters the event log.** Upstream's
  `_emit_llm_error_response` puts `message=str(e)` (raw provider exception
  text) into the failed-attempt payload; Chronicle's `llm.failed` error object
  redacts the generic-exception `message` to the exception class name —
  provider credentials / raw client identifiers must never be durable.
  Structured `LLMBehaviorError`/`ToolError` messages (framework-authored)
  pass through.
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
- [x] Structured `ReplayDivergenceError` message builders —
      `Chronicle::ReplayDivergenceError` now has the keyword-only
      `(event_id:, expected:, actual:)` constructor (preserving the legacy
      message-plus-attrs form for back-compat call sites) and a public
      `build_message` that discriminates the four divergence shapes by input
      (CONTRACT v1.0 #C1, upstream `_build_message`): `expected` starting with
      `prompt_hash=` → `prompt_hash_mismatch`, `embedding_hash=` →
      `embedding_hash_mismatch`, `<no recorded event>`/nil `actual` →
      `length_mismatch` (early-finish vs unrecorded-event sub-shapes),
      otherwise → `type_mismatch`. Every shape builds the locked
      `What failed:` / `Why:` / `How to fix:` structured message with the
      operator-facing `activegraph inspect <run> [--event N]` /
      `--pack-version` remediation prose; the `kind` getter and
      `context` (`event_id`/`kind`/`expected`/`actual`) carry the
      discriminator. `build_message` is public so strict-replay raise sites
      can render the same diagnostics without constructing the error.
      Divergence: upstream's Python `repr` renders the recorded/live types in
      single quotes; Crystal's `String#inspect` uses double quotes — the
      diagnostic text is identical otherwise. Ported
      from activegraph runtime/errors.py + test_errors_format.py +
      test_replay.py —
      `spec/chronicle/replay_divergence_error_spec.cr`.
- [x] Per-reason prose for structured error fields —
      `Chronicle::RuntimeReason.llm_prose(reason, message)` and
      `RuntimeReason.tool_prose(reason, message)` return the
      what_failed/why/how_to_fix triple for every CONTRACT v0.6 #11 LLM
      reason (`_LLM_REASON_PROSE` + fallback) and CONTRACT v0.7 #6 tool
      reason (`_TOOL_REASON_PROSE` + fallback), matching the voice principle
      (CONTRACT v1.0 #3: name the invariant, not the mechanism). `message`
      from the call site interpolates into what_failed; why/how_to_fix are
      reason-specific and stable. `LLMBehaviorError` and `ToolError` now
      derive their structured fields from the prose table at construction
      (preserving the `(reason, message, *, payload_extras=)` signature), so
      `.structured?` is true and `#to_s` renders the locked structured format
      with the reason/message/payload_extras context — the v1.0 PR-D format
      migration. Divergence: prose strings are ported verbatim; upstream
      `activegraph inspect` CLI idioms stay textual in the prose (the CLI
      subcommand surface is `chronicle-cli`). Ported from
      activegraph llm/errors.py + tools/errors.py —
      `spec/chronicle/error_prose_spec.cr`.
- [x] PR-E registration/execution error leaves —
      `Chronicle::MissingProviderError` (RegistrationError, fires at
      registration when an @llm_behavior has no wired provider; optional
      `behavior_name`, recovery shows real and recorded provider
      construction), `Chronicle::MissingToolError` (RegistrationError,
      enumerates the registered tools in what_failed with the `(+N more)`
      suffix past six and points at `Runtime(tools=)` + `load_pack`), and
      `Chronicle::UnknownToolError` (ExecutionError, lists the tool
      requested vs. the behavior's declared tools with `(none declared)`
      fallback). `UnknownToolError` is wired into the runtime: the LLM
      tool-loop's invoke site now raises it (with the registered tools) when
      the LLM asks for an undeclared tool, replacing the generic
      `GraphProjectionError`. Divergence: Chronicle's drive loop does not
      thread the current behavior's declared-tools list into `invoke_tool`,
      so `declared_tools` carries the runtime's registered tools rather than
      the behavior's declarations. Ported from activegraph llm/errors.py +
      tools/errors.py + test_errors_format.py —
      `spec/chronicle/error_registration_spec.cr`.
- [x] LLM-behavior tool loop with declared-tool invocation + unknown-tool
      refusal (CONTRACT v0.7 #6) — `execute_llm_behavior_request` now runs the
      upstream `_invoke_llm_body` turn loop: it resolves `behavior.tools` to
      registered tools (a declared-but-unregistered tool raises
      `MissingToolError`, folded to `behavior.failed reason="tool.unknown_tool"`
      with a `tool` extra), attaches the tool definitions to the request, and
      loops up to `max(1, behavior.max_tool_turns)` turns. Each turn calls the
      model; when the response carries tool calls, the runtime refuses any
      undeclared call (`refuse_undeclared_tool_calls` →
      `reason="tool.unknown_tool"`), invokes each declared call via
      `invoke_tool` (recording causally-linked `tool.requested` /
      `tool.responded`), appends the assistant turn + tool-result messages to
      the running conversation, and re-calls with the accumulated messages so
      each turn's prompt hash / cache key differs. A non-tool response breaks
      the loop; exhausting `max_tool_turns` without one raises a `ToolError`
      folded to `reason="tool.max_turns_exhausted"` with a `max_tool_turns`
      extra. The handler receives only the final non-tool output. Before each
      tool invocation the `max_tool_calls` budget gate runs
      (`enforce_tool_call_budget!`): a call that would exceed the allowance
      fails the behavior loud with `reason="budget.tool_calls_exhausted"` and a
      `tool` extra (upstream `_loop`'s pre-invocation budget check); each
      allowed call consumes one unit. At registration (`load_pack`), each LLM
      behavior's declared tool names are validated against the merged tool
      registry (`validate_behavior_tools`, upstream `_register_behaviors`
      MissingToolError guard, CONTRACT v0.7 #2): a declared-but-unresolvable
      tool raises `MissingToolError` and the `pack.loaded` event is never
      recorded — the misconfiguration fails before any LLM call burns budget.
      A tool may declare an `input_schema` (a `JSON::Serializable` struct via
      the `@[Tool(input_schema: ...)]` annotation); `invoke_tool` runs
      `validate_input!` before calling the body, so args that fail schema
      validation produce `behavior.failed reason="tool.invalid_input"` with a
      `tool` extra and the tool body never runs (upstream `_invoke_tool`'s
      input_schema.model_validate guard). Ported from
      activegraph tests/test_llm_tool_loop.py (one/two-turn chains,
      max_tool_turns exhaustion, max_tool_calls budget, unknown-tool refusal,
      missing-tool-at-registration, bad-tool-input) —
      `spec/chronicle/declared_tool_loop_spec.cr`,
      `spec/chronicle/unknown_tool_loop_spec.cr`,
      `spec/chronicle/tool_loop_budget_spec.cr`,
      `spec/chronicle/missing_tool_registration_spec.cr`,
      `spec/chronicle/tool_input_schema_spec.cr`.

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
- [x] LLM cache round-trips tool-call turns (v1.0.3 #4) —
      `response_cache_payload` now serializes every assistant content block
      (text + tool_use id/name/arguments) alongside `content`, and
      `completion_response_from_cache` / `choice_from_cache_payload`
      reconstructs them, so a cached tool-calling turn re-dispatches the tool
      on replay instead of degrading to a text-only response (upstream
      `_response_from_event_payload` hydrating `tool_calls` back into the
      response). The assistant turn in a re-call history carries both its text
      and its tool_use blocks (`Message.from(choice)`), matching Anthropic's
      tool_result→tool_use_id wire invariant. Ported from activegraph
      tests/test_v1_0_3_tool_multiturn.py —
      `spec/chronicle/cached_tool_turn_spec.cr`,
      `spec/chronicle/multiturn_tool_history_spec.cr`.
- [x] LLM provider network failure folds to `behavior.failed reason="llm.network_error"`
      — `invoke_llm_behavior`'s rescue runs `record_llm_behavior_failed`, which
      records errors that already carry a reason (LLMBehaviorError / ToolError /
      UnknownToolError / MissingToolError) verbatim and folds any generic
      provider / network exception into a new `LLMBehaviorError` with
      reason="llm.network_error", mirroring upstream `_invoke_llm_body`'s
      generic-exception catch. The folded error is never raised, so its
      backtrace is captured from the original exception before folding.
      Ported from activegraph tests/test_llm_failure.py::test_network_error_becomes_behavior_failed_with_reason —
      `spec/chronicle/llm_network_error_spec.cr`.
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
