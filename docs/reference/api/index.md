# API reference

The API reference documents the public surface of the
`Chronicle` module. Unlike upstream ActiveGraph, the Crystal surface
is not auto-generated from docstrings: these pages are a curated
signature reference derived from `src/chronicle/**/*.cr`. Symbols are
organized by topical module — runtime, graph, behaviors, tools,
store, packs, errors, observability — each as a separate page
navigated from the sidebar.

Two conventions apply across the reference:

- **Public surface and contracted extension suites.** The types and
  methods named in `src/chronicle.cr` and its `require`d files are the
  public surface. Reusable conformance helpers
  (`spec/chronicle/graph_store_conformance.cr`,
  `event_store_conformance.cr`, `trial_executor_conformance.cr`) live
  in `spec/` so adapter authors can validate implementations without
  widening the runtime namespace. Names prefixed with `_` or not
  required from `chronicle.cr` are implementation details.
- **No source dumps.** The reference renders the API contract, not the
  implementation. Readers who want source go to
  `src/chronicle/<module>.cr`.

The Crystal port is a compile-time language: many upstream runtime
checks (Pydantic schema validation, `isinstance` protocol checks) are
enforced by the compiler or expressed as `JSON::Serializable` structs.
Where a signature here differs from upstream in a behaviorally
meaningful way, the divergence is recorded in
[`plans/parity.md`](../../../plans/parity.md).

## Topical reference

- [Runtime](runtime.md) — the runtime loop, frames, budget, status,
  clocks, `LogAgent`.
- [Graph](graph.md) — `GraphProjection` and its primitives (objects,
  relations, patches, views, events, diffs, promote).
- [Behaviors](behaviors.md) — the pack behavior annotations and base
  classes.
- [Tools](tools.md) — the `@[Tool]` annotation and tool primitives.
- [Store](store.md) — event stores (memory, SQLite, Postgres), graph
  stores, URL parsing, migration.
- [Packs](packs.md) — the pack format primitives.
- [Errors](errors.md) — the `ActiveGraphError` hierarchy.
- [Observability](observability.md) — accepted-event sinks, the metrics
  protocol, logging, and shipped backends.
- [Sandbox](sandbox.md) — trial isolation value types and executors.

## Reference completeness

The upstream reference ships a generated docstring coverage report
(`COVERAGE_REPORT.md`) and a type report (`TYPE_REPORT.md`). Those are
generated artifacts and are intentionally **not** ported. Coverage for
this port is tracked in
[`plans/inventory/python_source_parity.tsv`](../../../plans/inventory/python_source_parity.tsv)
and summarized in [`plans/parity.md`](../../../plans/parity.md).
