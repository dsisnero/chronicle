# Migration from v0.7

This page is the runbook for bringing runs and code written against
ActiveGraph v0.7 forward through to the v1.0 surface, as expressed by
the Crystal **Chronicle** port. Each milestone added surface; backward
compatibility was preserved throughout, so the upgrades are additive —
your existing behaviors keep working as you adopt new primitives.

Three milestones span the upgrade path: **v0.8** added the Postgres
store, store URLs, migration, and the observability surface; **v0.9**
added the pack format and shipped the Diligence reference pack; **v1.0**
is the adoption-surface milestone — the per-error catalog, the docs,
the quickstart, and the gates. The Crystal port tracks these surfaces
with its own intentional divergences (see `plans/parity.md`).

The order below is the order to apply the changes. Skip steps that
don't apply.

## 1. Add the chronicle shard

```yaml
# shard.yml
dependencies:
  chronicle:
    github: dsisnero/chronicle
```

```bash
shards install
```

The optional Python extras (`anthropic`, `psycopg`, `prometheus_client`,
`pydantic`) map to Crystal shard dependencies that Chronicle already
declares in its own `shard.yml` (`sqlite3`, `pg`, `opentelemetry-sdk`,
`toml`). There is no per-feature `[all]` extra; the shard graph is the
install surface.

## 2. Migrate the store schema

The store `schema_version` is `"1"`. Runs written by older builds carry
their own. A mismatched Postgres schema raises an
`IncompatibleRuntimeState` at open time; SQLite reads the version from
its `meta` table.

To migrate a run forward:

```crystal
report = Chronicle::Migration.migrate("sqlite:///old.db", "sqlite:///new.db")
puts report.ok?
```

The migration is transaction-per-run, idempotent, and one-directional.
Each run migrates in a single transaction; a failed run leaves the
destination unchanged for that run, and re-running picks up where it
left off.

> **Deferred in this port (see `plans/parity.md`):** migration supports
> SQLite → SQLite. Postgres source/destination and the upstream
> `--skip-corrupted` recovery are not ported; `skip_corrupted: true`
> raises `IncompatibleRuntimeState`.

## 3. Adopt connection URLs (v0.7 → v0.8)

v0.7 store construction took a path argument. v0.8 added connection URLs
as the canonical addressing form, with the path form preserved as
shorthand for SQLite:

```crystal
# Bare path sugar (SQLite):
store = Chronicle::SQLiteEventStore.new("/path/to/run.db", run_id: "run-1")

# Explicit connection URL:
store = Chronicle::open_store("sqlite:////path/to/run.db", run_id: "run-1")
store = Chronicle::open_store("postgres://host/db", run_id: "run-1")
```

`Chronicle.parse_store_url` validates the grammar and returns a
`StoreURL`; an unsupported or schemeless URL raises `InvalidStoreURL`
naming the corrected form. The URL grammar is:

- `sqlite:///relative/path.db`
- `sqlite:////absolute/path.db`
- `postgres://user:password@host:port/dbname`
- `postgresql://…` (same scheme)

> **Divergence:** upstream's CLI is URL-addressed. The Crystal CLI is
> file/log-addressed (`chronicle-cli log inspect -f …`), and the store
> URL grammar is exercised through the library (`open_store`,
> `parse_store_url`) rather than through `inspect <url>`. See
> `plans/parity.md`.

## 4. Adopt the pack format (v0.8 → v0.9)

v0.9 introduced packs. If your older code declared behaviors, tools, and
object types as global decorators, the Crystal pack DSL replaces that
with annotations collected by `pack(...)`; the registration is
per-runtime instead of global:

```crystal
module MyPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "claim_extractor", on: ["object.created"])]
  def claim_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # ...
  end

  pack(name: "my_pack", version: "0.1.0")
end

runtime.load_pack(MyPack::PACK)
```

Loading a pack adds its behaviors and tools to the runtime. To author a
pack from existing code, see
[Authoring packs](../guides/authoring-packs.md). The shipped
`Chronicle::Packs::Diligence` is the reference example.

Two things to know if you're loading third-party packs:

- **Pack name conflicts.** Two loaded packs claiming the same canonical
  symbol raises `PackConflictError`. Rename one pack or load them in
  separate runtimes.
- **Pack version pinning.** A runtime holds at most one version of any
  pack; loading a different version raises `PackVersionConflictError`.

> **Divergence:** upstream decorators are `@behavior` / `@tool`; Crystal
> uses `@[Behavior]` / `@[Tool]` annotations, and settings injection is
> resolved at compile time (no runtime signature introspection). See
> `plans/parity.md`.

## 5. Adopt the v1.0 error hierarchy (v0.9 → v1.0)

Every exception the framework raises now inherits from
`Chronicle::ActiveGraphError`. The v1.0 hierarchy preserves builtin
lineage through `DomainError < ActiveGraphError < ArgumentError`, so
existing `rescue ArgumentError` clauses keep working:

```crystal
# v0.9 — these patterns still work in v1.0:
begin
  store.get_event(event_id)
rescue ex : Chronicle::EventNotFoundError
  # ...
end

begin
  graph.add_object("claim", bad_json)
rescue ex : ArgumentError
  # ...
end
```

The v1.0 hierarchy adds richer structured fields:

```crystal
begin
  runtime = Chronicle::Runtime(MyModel).load("/path/to/run.db", run_id, agent)
rescue ex : Chronicle::StorageError
  log(ex.what_failed, ex.how_to_fix, ex.context)
rescue ex : Chronicle::ActiveGraphError
  log(ex.message, ex.doc_url)
end
```

Structured errors carry `what_failed` / `why` / `how_to_fix` / `context`
and a `doc_url` under `https://docs.activegraph.ai/errors/<slug>`.

## 6. Adopt the v1.0 CLI follow-ons

Upstream v1.0 added five operator-facing CLI flags that error messages
reference in their recovery prose. The Crystal CLI is a thin,
file-addressed wrapper and does **not** ship those flags; the
programmatic equivalents are:

| Upstream flag | Crystal equivalent |
|---|---|
| `inspect --event <id>` | `runtime.store.get_event(id).try(&.payload)` |
| `inspect --behaviors` | `runtime.status.registered_behaviors` |
| `inspect --pack-version` | filter `runtime.store.iter_events` for `pack.loaded` |
| `fork --at-event <evt> --record` | `runtime.fork(at_event: evt, label: "…-recording")` |
| `migrate --from … --to … --skip-corrupted` | `Chronicle::Migration.migrate(src, dst)` (no `skip_corrupted`) |

See [Operating in production](../guides/operating-in-production.md#cli)
for the CLI surface the port does provide.

## 7. Adopt structured logging (v0.7 → v0.8)

v0.8 added structured logging with a documented schema. The Crystal port
owns the pure formatter/redaction logic; the platform edge writes the
line:

```crystal
line = Chronicle::Logging.format_line(
  timestamp: Time.utc.to_rfc3339,
  level: "INFO",
  logger: "chronicle.runtime",
  message: "event emitted",
  extras: Chronicle::Logging.runtime_log_extra(run_id: run_id, event_id: event.id),
)
```

The structured schema is documented under
[Operating in production](../guides/operating-in-production.md#structured-logging).

> **Divergence:** `configure_logging(level:, json_output:)` and
> `get_logger` are platform-edge and not ported. Use
> `Chronicle::Logging.format_line` /
> `Chronicle::Logging.set_payload_redactor` from your own logging
> adapter. See `plans/parity.md`.

## 8. Adopt the metrics protocol (v0.7 → v0.8)

v0.8 added a three-method `Metrics` interface with two shipped backends
(`NoOpMetrics` by default, Prometheus opt-in). Existing code without
metrics keeps working — `NoOpMetrics` is the default, so no surface
changes if you don't opt in. To enable Prometheus:

```crystal
metrics = Chronicle::PrometheusMetrics.new
runtime = Chronicle::Runtime(MyModel).new(
  store: store, log_agent: log_agent, graph: graph, metrics: metrics,
)
# Expose GET /metrics:
server = Chronicle::Prometheus::ScrapeServer.new(metrics)
server.start
```

See [Operating in production](../guides/operating-in-production.md#metrics)
for the metric names and the operator contract.

## Backward compatibility — what's guaranteed

The Crystal port is pinned against the vendor revision and tracks each
surface with specs. Where the port deliberately diverges from Python —
annotations instead of decorators, JSON strings instead of dicts,
Sans-IO instead of asyncio, the Crig `ModelExecutor` seam instead of
provider SDK clients, no `configure_logging`, no URL-addressed CLI —
the divergence is recorded in `plans/parity.md` under "Intentional
Divergence".

If something documented here doesn't work, that's a bug — file an issue
at <https://github.com/dsisnero/chronicle/issues>.

## What's related

- [Operating in production](../guides/operating-in-production.md) — the
  v0.8+ operator surface in detail.
- [Authoring packs](../guides/authoring-packs.md) — the v0.9 pack
  format reference.
- [Fork, test, promote](../guides/fork-test-promote.md) — the v1.3
  self-modification loop.
- `plans/parity.md` — the port's parity ledger and intentional
  divergences.
