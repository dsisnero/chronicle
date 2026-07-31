# Graph Infrastructure Port Plan

Port the remaining activegraph *graph infrastructure* — the `GraphStore`
backend abstraction, the graph query API, and the `IDGen` — into Clarity.
This is the layer underneath the pattern matcher already ported in
`src/clarity/patterns.cr`.

## Source of Truth

- **Upstream**: https://github.com/yoheinakajima/activegraph (Python)
- **Pinned revision**: `8aedb1866cf5dce056af97529152ffd6f468a1ed`
  (checkout at `vendor/activegraph/`)
- **DeepWiki**: https://deepwiki.com/yoheinakajima/activegraph

DeepWiki is guidance, not the source of truth. Its GraphStore description is
currently **stale** (it claims no GraphStore exists); validate every
behavior against the pinned source files:

- `activegraph/core/ids.py` — `IDGen`
- `activegraph/core/graph_store.py` — `GraphStore` ABC, `ChainMatch`, `InMemoryGraphStore`
- `activegraph/store/graph_conformance.py` — `GraphStoreConformance` suite
- `activegraph/store/falkordb.py` — `FalkorDBGraphStore` (pushdown example)
- `activegraph/core/graph.py` — `objects/relations/get_relations/neighborhood/objects_in_types` + `evaluate_where`/`_eval_where_on_object`

## Current State (Clarity)

- [x] Pinned upstream checkout at `vendor/activegraph/`
- [x] `Clarity::GraphObject`, `Clarity::GraphRelation`, `Clarity::Patch` structs in `graph_projection.cr`
- [x] `Clarity::GraphProjection#apply` (event → projection) and `#diff`
- [x] `Clarity::ChainMatch` and `Clarity::GraphProjection#match_chain` (InMemory default walk)
- [x] `Clarity.parse` / `Clarity::PatternMatcher` (Cypher subset)
- [x] `GraphProjection#patch_object`, `#propose_patch`, `#apply_patch`, `#reject_patch`, `#build_view`

## Missing (to port)

- [ ] `Clarity::IDGen` (objects/events/relations/patches/frames/runs + `reseed_from_events`)
- [ ] `Clarity::GraphStore` abstract backend (upsert/get/remove/enumerate + query hooks + lifecycle)
- [ ] `Clarity::InMemoryGraphStore` (default backend)
- [ ] `Clarity::GraphStoreConformance` spec suite (pins backend contracts)
- [ ] Graph query API on `GraphProjection`: `get_relation`, `objects(type:, where:)`,
      `relations(source:, target:, type:)`, `get_relations`, `objects_in_types`,
      `has_object_of_type`, `neighborhood`
- [ ] `where` predicate evaluator on bare objects (dotted paths + operator dicts)
- [ ] Projection delegates state to a `GraphStore` (projector writes through the backend)
- [ ] Optional external backend demonstrating query pushdown (SQLite-backed GraphStore)

---

## Phase 0 — Preflight

- [x] Confirm pinned source checkout and record revision (see above)
- [x] Consult DeepWiki for GraphStore context; reconcile against pinned source
- [x] Confirm parity inventory and plan locations (`plans/inventory/`, `plans/parity.md`)

## Phase 1 — IDGen

Port `activegraph/core/ids.py` as `Clarity::IDGen` in `src/clarity/ids.cr`.

ID contracts (per-graph monotonic counters):
- `object(type)` → `"#{type}##{n}"` — **global** counter, not per-type
- `event` → `"evt_#{n:03d}"`
- `relation` → `"rel_#{n:03d}"`
- `patch` → `"patch_#{n:03d}"`
- `frame` → `"frame_#{n:03d}"`
- `run` → 26-char Crockford base32 ULID (time-prefixed + random suffix)
- `reseed_from_events(events)` → set counters past the highest id seen
  (regex `^[a-zA-Z]+_\d+$` for sequence ids; `^[^#]+#\d+$` for object ids)

**Note:** `run`/ULID uses wall-clock + secure randomness. Clarity permits time
and randomness in the core — only routing must stay deterministic — so this
mirrors upstream. (The core I/O safety gate forbids only direct I/O and
process capabilities.)

Tasks:
- [x] Write `spec/clarity/ids_spec.cr` (red) porting upstream `test_ids.py` behavior:
      monotonic per-kind counters, global object counter (`task#1`, `task#2`, `claim#3`),
      zero-padded event ids, reseed-from-events after replay
- [x] Implement `Clarity::IDGen` with deterministic counters + `run`/ULID
- [x] Relax the core I/O-safety spec and implementation.md: core may use
      clocks/randomness; only routing stays deterministic (Sans-IO boundary kept)
- [x] Run focused spec + gates

## Phase 2 — GraphStore backend seam

Port `activegraph/core/graph_store.py` as `Clarity::GraphStore` (abstract) +
`Clarity::InMemoryGraphStore` in `src/clarity/graph_store.cr`.

Required abstract methods (per entity kind, id-keyed):
- [ ] `put_object`, `get_object`, `remove_object`, `all_objects`
- [ ] `put_relation`, `get_relation`, `remove_relation`, `all_relations`
- [ ] `put_patch`, `get_patch`, `all_patches` (+ `remove_patch` default raising)

Optional query hooks (working defaults over `all_objects`/`all_relations`;
a backend may push down but MUST return what the default would):
- [ ] `find_objects(type : String?)`
- [ ] `find_objects_in_types(types : Array(String))` (OR, single-pass order, `[]` → `[]`)
- [ ] `find_relations(source:, target:, type:)` (AND; dangling endpoints must work)
- [ ] `neighborhood(object_id, depth = 1)` (undirected BFS; `([], [])` if not an object;
      walk through placeholder endpoints)
- [ ] `match_chain(node_types, rels)` delegating to the DFS already in `GraphProjection`

Lifecycle:
- [ ] `clear`, `close`

Contract invariants to pin in specs:
- [ ] `put_*` is an upsert (overwrite by id)
- [ ] `get_*` returns nil for unknown ids; `remove_*` no-ops on unknown ids
- [ ] Hooks use only entity attributes — never the WHERE predicate language
- [ ] `match_chain` is homomorphic (self-loop reuse) — no backend may switch to isomorphism

## Phase 3 — GraphStoreConformance suite

Port `activegraph/store/graph_conformance.py` as a reusable spec mixin
`spec/clarity/graph_store_conformance_spec.cr` (or a shared module the
in-memory backend spec includes).

Tasks:
- [ ] `make_store` hook returning a fresh `InMemoryGraphStore`
- [ ] Round-trip, upsert-overwrite, unknown → nil, no-op remove, `clear`
- [ ] `find_objects`, `find_objects_in_types` (empty → `[]`, OR, order), `find_relations`
- [ ] `neighborhood`: depth 0, placeholder walks, cycle handling
- [ ] `match_chain`: single node, one-hop directions, multi-hop,
      homomorphic self-loop, branching/cycles
- [ ] Run the suite against `InMemoryGraphStore`; keep it reusable for future backends

## Phase 4 — Graph query API on GraphProjection

Port `activegraph/core/graph.py` read surface (`objects`, `relations`,
`get_relations`, `neighborhood`, `objects_in_types`, `has_object_of_type`)
and the `where` predicate evaluator.

- [ ] `get_relation(id)` (missing today)
- [ ] `objects(type : String? = nil, where : Hash(String, JSON::Any)? = nil)`
      — type filter pushed down, `where` evaluated in Clarity
- [ ] `relations(source:, target:, type:)` — canonical AND filter API
- [ ] `get_relations(object_id, type, direction)` — legacy `(object_id, direction)`
      alias; `"both"` pushes type filter and applies membership in Clarity
- [ ] `objects_in_types(types)` — used by `build_view`
- [ ] `has_object_of_type(type)`
- [ ] `neighborhood(object_id, depth = 1)` on the projection
- [ ] `where` predicate evaluator (dotted keys + `{op: value}` dicts), mirroring
      the operator table already in `patterns.cr` (equality + ordered comparisons
      with the same nil/comparable-type semantics)
- [ ] Port upstream `test_graph.py` query tests as characterization specs
- [ ] Run focused specs + gates

## Phase 5 — Projection delegates to a GraphStore

Refactor `GraphProjection` so `@objects/@relations/@patches` live behind a
`GraphStore` backend instead of inline hashes; `apply` becomes the only writer
and writes **through** the store (mirroring upstream's projector → GraphStore).

- [ ] `GraphProjection` constructor accepts a `GraphStore` (default `InMemoryGraphStore`)
- [ ] `apply` mutates via `put_*`/`remove_*` rather than rebuilding hash copies
- [ ] `objects`/`relations`/`patches` accessors delegate to `all_*`
- [ ] `get_object`/`get_relation`/`get_patch` delegate to the store
- [ ] `match_chain`/`find_objects`/`find_relations`/`neighborhood` delegate
      to the store hooks
- [ ] Keep replay purity: `GraphProjection.replay(events)` still deterministic
- [ ] Ensure existing `graph_projection_spec`, `view_spec`, `patterns_*_spec`
      remain green with no behavioral change
- [ ] Red-green: characterization specs first, then refactor

## Phase 6 — Optional: SQLite-backed GraphStore (pushdown example)

Mirror `FalkorDBGraphStore`'s role: an external backend that overrides query
hooks (`find_objects_in_types`, `neighborhood`, `match_chain`) with pushed-down
queries, and proves the conformance suite keeps backends interchangeable.

- [ ] `Clarity::SQLiteGraphStore` using the existing `sqlite3.cr` dependency
- [ ] Override `match_chain`/`neighborhood` with SQL traversals (order aside)
- [ ] Run the conformance suite against it
- [ ] Wire an env/config switch (analogous to upstream `graph_store=` param)
- [ ] Mark as stretch — not required for parity completion

## Phase 7 — Parity tracking, docs, gates

- [ ] Update `plans/inventory/python_port_inventory.tsv` with all new
      `ported` entries (ids, graph_store, Graph query API, conformance)
- [ ] Update `plans/parity.md` Done table and any Intentional Divergence notes:
      - JSON-string `data` vs Python dict (already documented)
      - placeholder-node demotion only matters for the external backend
      - `run` ULID randomness is non-deterministic by design (mirror upstream)
- [ ] Run full gates: `crystal tool format --check src spec`,
      `ameba src spec`, `crystal spec`

---

## Acceptance Gates

- [ ] `IDGen` produces upstream-identical id shapes and reseeds past a replayed log
- [ ] Any backend passes the full `GraphStoreConformance` suite
- [ ] `GraphProjection` query API matches upstream `Graph` read-surface semantics
- [ ] Replaying the same events yields the same projection regardless of backend
- [ ] All existing specs stay green (no behavioral regression)

## Design Notes / Divergences to Decide

- Clarity splits upstream `Graph` into `EventLog` (append-only source) +
  `GraphProjection` (projection). The GraphStore seam lives on the projection
  side; `EventLog`/`EventStore` are not the same abstraction (upstream says
  losing a GraphStore is recoverable, losing the EventStore is not).
- `_OPS` in `graph.py` shares the operator semantics already ported to
  `patterns.cr` — reuse `PatternMatcher`'s comparison helpers instead of
  duplicating.
- The upstream `where` predicate for `objects()` is a dict language distinct
  from Cypher WHERE; port it as `Clarity::GraphProjection#objects(where:)`.
