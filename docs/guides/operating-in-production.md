# Operating Chronicle

This document is for **operators**: people responsible for running a
Chronicle runtime as part of a system other people depend on. The
README is for developers writing behaviors. The audience is different
and so is this document.

If you are evaluating Chronicle, read the README first. If you have a
behavior that doesn't run on your machine, the README will help. If you
have a behavior that runs fine on your machine but you need to put it
somewhere a team can rely on it, you are in the right place.

The companion example is `examples/operate_a_run.cr`. Read it alongside
this guide as the executable spine of the operator loop.

---

## The operator surface

The framework treats the boundary between itself and the world it runs
in as a load-bearing contract. Six primitives compose that surface;
together they make a run inspectable, observable, and recoverable
without reading source code:

1. **Postgres** as a second `EventStore`, behind the same interface as
   SQLite. Same schema shape, same semantics, different driver.
2. **Structured logging** with a documented JSON schema. One log line
   per event, every line carries `run_id` / `event_id` when applicable.
3. **Metrics**: a three-method `Metrics` interface with a
   `NoOpMetrics` default plus reference `PrometheusMetrics` and
   `OpenTelemetryMetrics` implementations. The runtime emits a fixed,
   documented set of counters, histograms, and gauges. Custom backends
   (Datadog, statsd, internal collectors) implement the interface —
   three methods.
4. **Event sinks**: the bounded, isolated `Sink` interface streams
   accepted live events to observational adapters without putting
   adapter I/O on the runtime hot path. `JSONLSink` is the first-party
   local adapter; queue loss and failures are visible in status and
   metrics.
5. **`chronicle-cli`**: `route preview`, `diff`, `log inspect`,
   `replay`, `trace`, `session list`, `fork`, `chat`, `quickstart`. The
   CLI is a thin wrapper around library APIs; anything it does,
   programmatic callers can do too.
6. **Runtime introspection**: `runtime.status` returns a frozen
   snapshot of queue depth, budget remaining, registered behaviors,
   recent events, and current frame. The CLI's `log inspect` command
   sits on top of the same data.

What the framework deliberately does **not** ship: a web UI, an HTTP
server for the run loop, a distributed runtime, built-in
websocket/SSE transport, multi-model LLM routing, or streaming LLM
responses. The `Sink` seam is the sanctioned boundary for a UI or
transport adapter; those products and protocols are not baked into the
runtime. (A small HTTP scrape server exists solely for Prometheus —
see [Metrics](#metrics).)

> **Port divergence.** Several upstream operator surfaces are
> platform-edge and intentionally not ported. See
> `plans/parity.md` for the full ledger; the notable ones are called
> out inline below.

---

## Persistence: SQLite vs Postgres

SQLite is the default and the right answer for solo work, demos,
ephemeral runs, and most single-machine production cases. The event
log fits in one file, WAL mode gives you crash-safe writes, and you
have no operational dependencies.

Postgres is the right answer when:

- More than one process or machine needs to inspect a run (the operator
  on a laptop, a dashboard, a CLI on a jump box, a CI job).
- You already operate Postgres and want one fewer storage system.
- You want to put the JSONB column behind a read replica or pipe it
  into your data warehouse.

Both stores conform to the same `EventStore` interface. The runtime,
the CLI, and every library API treat them identically. **Migration is
one-directional and explicit** (see below).

### Connection URLs

Stores are addressed by URL throughout the framework — runtime, CLI,
library APIs. The schemes follow the SQLAlchemy convention:

- `sqlite:///relative/path.db` (**three** slashes — relative path)
- `sqlite:////absolute/path/to/run.db` (**four** slashes — absolute
  path; the leading `/` of the absolute path adds the fourth slash)
- `postgres://user:password@host:port/dbname`
- `postgresql://user:password@host:port/dbname` (same scheme)

A path with no scheme is an error. The framework will not guess.
`Chronicle.parse_store_url("run.db")` raises `InvalidStoreURL` with a
message pointing here. Use `sqlite:///run.db` (relative) or
`sqlite:////tmp/run.db` (absolute). `Chronicle.open_store(url, run_id:
...)` dispatches to the right backend.

### Postgres setup

```bash
# Postgres 16 or newer, anywhere reachable from the runtime.
createdb chronicle_prod
# Schema is created lazily on first connection. No migration step.
shards install    # the pg shard is a normal dependency
```

The first time the runtime opens a Postgres URL it issues
`CREATE TABLE IF NOT EXISTS` for `events`, `runs`, and `meta`,
mirroring the SQLite schema with Postgres-native types
(`BIGSERIAL`, `JSONB`, `TIMESTAMPTZ`). Schema version is stored in
`meta` and verified on every open. A schema version mismatch is a
hard error — the runtime refuses to operate on a log it does not
understand.

### Connection management

`PostgresEventStore.new(url, run_id: ...)` opens a single `DB::Database`
from the connection URL itself. Connection/cursor/transaction pooling
is delegated to `crystal-db`; there is no separate `psycopg`-style
pool object or borrowed-connection constructor. Runtimes that need
pooling configure the `crystal-db` driver.

> **Divergence:** upstream accepts a `psycopg.Connection` or a
> `psycopg_pool.ConnectionPool`. The Crystal adapter accepts a URL and
> leaves pooling to `crystal-db`. See `plans/parity.md`.

### Migration (transaction-per-run)

```crystal
report = Chronicle::Migration.migrate(
  "sqlite:///path/to/dev.db",
  "sqlite:////tmp/chronicle_prod.db",
)
report.runs.each do |run|
  puts "#{run.status} run=#{run.run_id} events=#{run.events_migrated}"
end
```

Migration semantics:

- Each run in the source migrates in **a single transaction** against
  the destination. If a run fails partway, that run's destination
  state is unchanged.
- Migration is **idempotent** at the event level: writes use
  `INSERT OR IGNORE` against the `UNIQUE(id, run_id)` index. Re-running
  migration after a partial failure resumes safely.
- Runs are migrated independently. A bad run does not block the others.
- The default migrates **all** runs in the source. Pass
  `only_run_ids:` to pick a subset.
- A per-run report is returned (`Report#runs`, `Report#failures`,
  `Report#ok?`). Each entry is `{run_id, status, events_migrated,
  error?}`.
- Migration is **not bidirectional**. There is no `sync` mode and no
  rollback. To go back, migrate the other direction.

> **Deferred in this port (see `plans/parity.md`):** migration currently
> supports SQLite → SQLite only. Postgres as a migration source or
> destination is not ported, and `skip_corrupted:` raises
> `IncompatibleRuntimeState` rather than recovering a partial run.

When migration is the right tool: you are graduating a run from a
laptop SQLite file to a shared database, or moving a historical
archive. When it is the wrong tool: you are trying to keep two stores
in sync. Don't.

---

## Structured logging

The framework emits structured log records through `Chronicle::Logging`.
**It does not auto-configure logging on import**, and it does not write
to a global logger: the core is Sans-IO and owns only the pure
formatter/redaction logic. The platform edge supplies the timestamp and
writes the line.

If you want the JSON form:

```crystal
line = Chronicle::Logging.format_line(
  timestamp: Time.utc.to_rfc3339,
  level: "INFO",
  logger: "chronicle.runtime",
  message: "event emitted",
  extras: Chronicle::Logging.runtime_log_extra(run_id: "run-1", event_id: "evt_005"),
)
puts line
```

Every log line is one JSON object on one line, suitable for ingestion
by Loki, Splunk, BigQuery, Cloud Logging, or any other line-oriented
log aggregator.

### Log schema

Every line is a JSON object. These fields appear when applicable.
Fields that don't apply are **omitted**, not nulled:

| Field             | Type    | When                                             |
|-------------------|---------|--------------------------------------------------|
| `timestamp`       | string  | always (ISO 8601, UTC; supplied by the caller)   |
| `level`           | string  | always (`DEBUG` / `INFO` / `WARNING` / `ERROR` / `CRITICAL`) |
| `logger`          | string  | always (e.g. `chronicle.runtime`)                |
| `message`         | string  | always                                           |
| `run_id`          | string  | any log line associated with a specific run      |
| `event_id`        | string  | log lines about a specific event                 |
| `behavior`        | string  | log lines about a specific behavior invocation   |
| `tool`            | string  | log lines about a tool invocation                |
| `model`           | string  | log lines about an LLM call                      |
| `cache_hit`       | bool    | LLM/tool calls; true if served from cache        |
| `cost_usd`        | string  | LLM calls that incurred cost (decimal as string) |
| `latency_seconds` | number  | LLM/tool/behavior calls with measured latency    |
| `reason`          | string  | failure log lines                                |
| `error_type`      | string  | failure log lines                                |
| `error_message`   | string  | failure log lines                                |
| `doc_url`         | string  | failure log lines (`More:` URL for the reason)   |

The schema is **the operator contract**. Dashboards built against
these field names will keep working across framework versions.
Breaking the schema is a breaking change.

`runtime_log_extra` builds the extras hash (dropping nil values and
renaming collisions with reserved log-record attribute names to an
`ag_` prefix).

### Level discipline

| Level    | What                                                          |
|----------|---------------------------------------------------------------|
| DEBUG    | View construction, prompt assembly, cache lookup, queue ops   |
| INFO     | Every event emitted, every behavior invoked, every tool call  |
| WARNING  | Budget approaching limits, retries, pattern eval slowness    |
| ERROR    | `behavior.failed` with non-budget reasons                     |
| CRITICAL | Event log inconsistency, schema mismatch, replay divergence  |

The trace printer (`runtime.trace.lines`) is a developer tool, not an
operator tool — it returns text the caller prints. It is independent of
the logging configuration.

### Payload redaction

LLM behaviors include rendered prompts in DEBUG logs. Tool responses
include their full payloads. Goals can contain anything the user typed.
If your environment requires redaction (PII, secrets, customer data):

```crystal
Chronicle::Logging.set_payload_redactor(->(payload : Hash(String, JSON::Any)) {
  payload.transform_values { |value| JSON::Any.new("<redacted>") }
})
```

The redactor runs on any payload before it enters a log record's extras.
It does not affect the event log itself — the source of truth keeps the
original. Redaction is a logging concern.

> **Divergence:** upstream's `configure_logging(level:, json_output:,
> payload_redactor:)` / `get_logger` (stdlib logging handler setup) are
> platform-edge and not ported. `format_line`, `runtime_log_extra`, and
> the redactor are the Sans-IO pieces Chronicle owns. See
> `plans/parity.md`.

---

## Event sinks

A `Sink` is offered every live event only after it has entered the log
and updated the projection (and, when configured, reached the durable
`EventStore`). Each attachment has its own bounded queue, so a slow or
failing adapter cannot block behavior execution or another sink. The
Crystal core is single-threaded; `runtime.flush_sinks` drains the
queues synchronously rather than via daemon workers.

```crystal
require "chronicle"

store = Chronicle::SQLiteEventStore.new("run.db", run_id: "ops")
graph = Chronicle::GraphProjection.empty.attach_store(store)
agent = Crig::Agent(MyModel).new(model: MyModel.new, preamble: "")
log_agent = Chronicle::LogAgent(MyModel).new(agent, store: store)

rt = Chronicle::Runtime(MyModel).new(
  store: store,
  log_agent: log_agent,
  graph: graph,
  run_id: "ops",
  sinks: [
    Chronicle::SinkConfig.new(
      Chronicle::JSONLSink.new("audit-jsonl", File.open("accepted-events.jsonl", "a")),
      name: "audit-jsonl",
      queue_capacity: 2048,
      overflow_policy: Chronicle::OverflowPolicy::DropNewest,
    ),
  ],
)

rt.run_goal("build the report")
rt.flush_sinks
rt.sink_statuses.each { |name, status| puts "#{name}: #{status.delivered}" }
rt.close_sinks
```

The defaults are capacity 1024 and `DropNewest`. The other declared
policies are `DropOldest` and `FailSink`; none waits for capacity.
Every overflow is counted in `SinkStatus` and the standard sink metrics.
`TestingSink` is the in-memory double for application tests;
`RaisingSink` proves sibling isolation.

Normal `Runtime.load`, `fork`, and strict replay never redeliver history
to live sinks. Passing `sinks:` to those APIs attaches them only after
the recorded history (including snapshot-backed history) has rebuilt
the graph. The first newly emitted event is the first delivery.
Historical sink export is deliberately a separate mode so an operator
can never mistake replayed history for live activity.

`JSONLSink` writes one canonical UTF-8 envelope per line with
`context` (`run_id`, one-based sequence, `mode="live"`) and the complete
event. It appends and does not rotate files.

> **Divergence:** upstream `flush_sinks(timeout=...)` /
> `close_sinks(timeout=...)` accept timeouts and run daemon workers.
> The Crystal core is Sans-IO and single-threaded, so those calls take
> no timeout argument. See `plans/parity.md`.

---

## Metrics

The framework emits metrics through a three-method `Metrics` interface:

```crystal
abstract class Chronicle::Metrics
  abstract def counter(name : String, tags : Hash(String, String), value : Float64 = 1.0) : Nil
  abstract def histogram(name : String, tags : Hash(String, String), value : Float64) : Nil
  abstract def gauge(name : String, tags : Hash(String, String), value : Float64) : Nil
end
```

That's it. Three methods. No timers (use a histogram with a latency
value). No summaries. No custom types. Implementations must be
thread-safe because independent runtime and sink workers may share one
metrics backend.

```crystal
metrics = Chronicle::PrometheusMetrics.new
rt = Chronicle::Runtime(MyModel).new(store: store, log_agent: log_agent, graph: graph, metrics: metrics)
```

To expose the Prometheus text format over HTTP:

```crystal
server = Chronicle::Prometheus::ScrapeServer.new(metrics, host: "127.0.0.1", port: 0)
address = server.start   # GET /metrics on the bound address
# ...
server.close
```

For OpenTelemetry, the application owns the `OpenTelemetry::Meter` and
any exporter lifecycle:

```crystal
otel = Chronicle::OpenTelemetryMetrics.new(meter)
rt = Chronicle::Runtime(MyModel).new(store: store, log_agent: log_agent, graph: graph, metrics: otel)
```

The default is `NoOpMetrics`, which does nothing. The runtime is fully
functional with no metrics configured.

For Datadog, statsd, or anything else: subclass `Metrics` with the same
three methods.

### Standard metrics

These metrics are emitted by the runtime. Names follow Prometheus
conventions (snake_case, `_total` for counters, `_seconds` for duration
histograms, `_usd` for cost histograms). They are the **operator
contract**: dashboards built against these names keep working across
framework versions.

| Name                                            | Type      | Tags                  |
|-------------------------------------------------|-----------|-----------------------|
| `activegraph_events_emitted_total`              | counter   | `event_type`          |
| `activegraph_behaviors_invoked_total`           | counter   | `behavior`            |
| `activegraph_behaviors_failed_total`            | counter   | `behavior`, `reason`  |
| `activegraph_behaviors_duration_seconds`        | histogram | `behavior`            |
| `activegraph_llm_calls_total`                   | counter   | `model`               |
| `activegraph_llm_cache_hits_total`              | counter   | `model`               |
| `activegraph_llm_failed_total`                  | counter   | `model`, `reason`     |
| `activegraph_llm_tokens_in`                     | histogram | `model`               |
| `activegraph_llm_tokens_out`                    | histogram | `model`               |
| `activegraph_llm_cost_usd`                      | histogram | `model`               |
| `activegraph_tools_calls_total`                 | counter   | `tool`                |
| `activegraph_tools_cache_hits_total`            | counter   | `tool`                |
| `activegraph_tools_failed_total`                | counter   | `tool`, `reason`      |
| `activegraph_tools_duration_seconds`            | histogram | `tool`                |
| `activegraph_queue_depth`                       | gauge     | (none)                |
| `activegraph_sink_queue_depth`                  | gauge     | `sink`, `run_id`      |
| `activegraph_sink_events_delivered_total`       | counter   | `sink`                |
| `activegraph_sink_events_dropped_total`         | counter   | `sink`, `reason`      |
| `activegraph_sink_errors_total`                 | counter   | `sink`, `operation`   |
| `activegraph_budget_cost_remaining_usd`         | gauge     | `run_id`              |
| `activegraph_budget_events_remaining`           | gauge     | `run_id`              |
| `activegraph_patterns_evaluated_total`          | counter   | (none)                |
| `activegraph_patterns_evaluation_duration_seconds` | histogram | (none)            |
| `activegraph_replay_divergence_detected_total`  | counter   | `reason`              |

`Chronicle::MetricsTable::METRIC_NAMES` is the machine-readable source
of truth. **Adding a metric is a public API change.** The list is
documented and test-pinned. New metrics get added in named releases,
not silently.

> **Divergence:** upstream `PrometheusMetrics` lazy-imports
> `prometheus_client` and ships a scrape server; the Crystal port
> records samples in memory, renders the text exposition with
> `Chronicle::Prometheus.render`, and binds `GET /metrics` in
> `Prometheus::ScrapeServer`. `OpenTelemetryMetrics` requires an
> application-owned `OpenTelemetry::Meter`. See `plans/parity.md`.

### Cardinality rule (locked)

> `run_id` MAY appear as a tag on **gauges of active state** (where
> cardinality is bounded by the number of concurrently active runs).
> `run_id` MUST NOT appear as a tag on **counters or histograms**.

`MetricsTable.validate_cardinality_rule` enforces this against the
standard metric list; a counter/histogram declaring `run_id` raises
`MetricsError` at load. If you implement a custom `Metrics` backend, do
the same.

### Tag conventions

Standard tag keys are: `event_type`, `behavior`, `tool`, `model`,
`sink`, `operation`, `reason`, `run_id` (gauges only). Boolean tags
(`cache_hit` is modeled as a separate counter rather than a tag — see
`activegraph_llm_cache_hits_total`).

Custom tags beyond the standard set are fine but may explode
cardinality. The cardinality rule above is your guide.

---

## Runtime introspection

`runtime.status` returns a `RuntimeStatus` — a frozen value struct.
Calling it is cheap: no behavior fan-out. It is safe to call from any
thread.

```crystal
status = rt.status
puts "#{status.run_id} #{status.state} #{status.queue_depth}"
status.recent_events.each { |ev| puts "#{ev.id} #{ev.type}" }
status.to_h   # JSON-serializable form (matches upstream field names)
```

Shape:

```crystal
struct Chronicle::RuntimeStatus
  getter run_id : String
  getter state : RuntimeState                 # Idle | Running | Stopped | Exhausted
  getter queue_depth : Int32
  getter events_processed : Int64
  getter budget : BudgetSnapshot
  getter frame : FrameSnapshot?
  getter registered_behaviors : Array(BehaviorInfo)
  getter recent_events : Array(EventSummary)
end
```

`recent_events` is a fixed 20-event tail in this port (upstream's
`status(recent: N)` accepts a length). There is **no `last_error`
field**. Errors are events. Filter `recent_events` for type
`behavior.failed`, use `runtime.errors`, or query the event store
directly for a window-independent view.

---

## CLI

The `chronicle-cli` binary is a thin wrapper around library APIs. It
operates on **encoded event-log files** (`EventLogCodec`) and SQLite
sessions rather than store URLs — see `plans/parity.md`. A programmatic
user can do everything the CLI does.

```bash
chronicle-cli route preview -c <config> -t <text> [-i <intent>]
chronicle-cli diff -a <before-log> -b <after-log>
chronicle-cli log inspect -f <log-file>
chronicle-cli replay -f <log-file>
chronicle-cli trace -f <log-file> -o <object-id>
chronicle-cli session list
chronicle-cli fork -f <from-log> -a <sequence> [-o <out-log>]
chronicle-cli chat
chronicle-cli quickstart
```

> **Divergence:** upstream's URL-addressed `inspect <url>`,
> `export-trace`, `migrate`, `pack`, and `promote` subcommands are not
> in the Crystal CLI. Use the library equivalents:
> `runtime.status` / `runtime.errors`, `runtime.export_trace`,
> `Chronicle::Migration.migrate`, `Chronicle::Packs`, and
> `runtime.promote`. See `plans/parity.md`.

### Exit codes

The upstream CLI documents a fixed exit-code contract (0 success, 1
generic error, 2 usage, 3 not found, 4 corruption, 5 divergence). The
Crystal `Chronicle::CLI` returns its output as a `String` and is
intended to be embedded; **process exit codes are not part of the port
yet**. Shell scripts that need exit codes should drive the library APIs
directly and choose their own codes. See `plans/parity.md`.

### `log inspect`

Prints every event in an encoded log file with its sequence, type, id,
actor, timestamp, frame, and payload.

```bash
chronicle-cli log inspect -f run.log
```

The library equivalent is iterating `runtime.store.iter_events` or
`runtime.trace.events`.

### `replay`

Reconstructs the projection from a log without firing behaviors, then
prints a summary: event count, object count, relation count, effect
count. Useful for sanity-checking a run after a crash or migration.

```bash
chronicle-cli replay -f run.log
```

The library equivalent is `Chronicle::ReplayEngine.new.replay(events,
Chronicle::ReplayMode::Permissive)`.

### `fork`

Creates a new encoded log by copying events up to and including a
sequence point. Prints the new log path and event count.

```bash
chronicle-cli fork -f run.log -a 42 -o fork.log
```

The forked log is dormant — nothing is running it. To continue from the
fork point as a live runtime, use the library `Runtime#fork(at_event:)`,
which is SQLite- and lineage-aware.

For an interactive single-writer host, prefer cooperative quanta and
place the next quantum behind any already-pending reads or commands:

```crystal
result = rt.run_quantum(max_queue_events: 25, max_seconds: 0.25)
schedule_next_quantum unless result.idle || result.budget_exhausted
```

One queue event and its behavior fan-out remain atomic. Yielding writes
no `runtime.idle`, so restart recovery and replay remain unchanged.

### `diff`

Structural diff between two encoded logs. Prints shared and divergent
event counts, divergent objects, and divergent relations.

```bash
chronicle-cli diff -a parent.log -b fork.log
```

The library equivalent is `parent.diff(other)`.

### `trace`

Renders a causal chain from an object back to its goal, walking
`caused_by` links.

```bash
chronicle-cli trace -f run.log -o claim#1
```

The library equivalent is
`Chronicle::Trace.causal_chain(events, graph, object_id)`.

### `session list`

Lists saved session files in the session store directory.

### `chat` / `quickstart`

`chat` starts an interactive session against a configured provider;
`quickstart` runs the offline, fixture-backed Diligence transcript.

### Migration

See [Migration](#migration-transaction-per-run). Use the library
`Chronicle::Migration.migrate(source_url, dest_url, only_run_ids:)`.
There is no `migrate` subcommand.

---

## Runbook

### A run is stuck

Call `runtime.status` (or `chronicle-cli log inspect`). Check `state`:

- `idle` — the queue is empty, the budget is fine, the run is waiting
  for new input. This is the normal terminal state for a goal-driven
  run. Not stuck.
- `exhausted` — the run hit a budget limit. The `budget` field shows
  which dimension. Raise the limit or accept the partial result.
- `running` — the run is actually working. `queue_depth` should be
  decreasing. If it's increasing or steady, a behavior is producing
  events faster than the runtime processes them. Check the trace.
- `stopped` — the runtime is loaded but no `run_until_idle` call is in
  progress. Call it.

### A run is over budget

`runtime.status.budget` shows used vs. limits across dimensions (events,
behavior calls, LLM calls, tool calls, cost, depth, seconds). Set up an
alert on `activegraph_budget_cost_remaining_usd < threshold` to catch
runs before they exhaust.

To resume a budget-exhausted run with a higher limit:

```crystal
rt = Chronicle::Runtime(MyModel).load(
  "run.db", "stuck-run", agent,
  budget: Chronicle::Budget.new(limits: {"max_cost_usd" => "10.0"}),
)
rt.run_until_idle
```

### Replay diverges

You loaded with `replay_strict: true` and got `ReplayDivergenceError`.
The runtime's re-execution of recorded behaviors produced different
events than the log. Causes, in order of likelihood:

1. A behavior reads from a non-deterministic source (clock, `Random`,
   network) it didn't read on the original run.
2. A behavior depends on a value (an LLM response, a tool result) that
   was cached on the original run but no longer is.
3. The framework version changed and an event payload shape changed.
   The schema-mismatch guard catches most of these; if not, file an
   issue.

The error pins the offending event id. Look at it. The fix is in your
behavior, not the framework.

### Postgres connection saturated

Each `PostgresEventStore` opens one `DB::Database`. If you need a pool,
configure the `crystal-db` driver rather than constructing a store per
request.

### Trace lines do not appear in my log aggregator

`runtime.trace.lines` returns text; it is not a log. To get events into
your aggregator, use `runtime.export_trace` (structured JSON) or write a
behavior that subscribes to the event types of interest and emits a
structured record through `Chronicle::Logging`.

### A local gate needs a development override

There is no global development mode. Record one exact receipt, then make
the local gate validate it for the same target, scope, and required
authority:

```crystal
receipt = rt.dev_override(
  actor: "local-developer",
  reason: "exercise fixture approval in a local run",
  target_gate: "pack.fixture.approval",
  scope: "pack:demo/fixture:one",
  resulting_authority: "R2",
)

if rt.validate_dev_override(
     receipt,
     target_gate: "pack.fixture.approval",
     scope: "pack:demo/fixture:one",
     required_authority: "R1",
   )
  run_local_fixture_path
end
```

`dev.override` is accepted into the ordinary event log before a receipt
is returned. It cannot target promotion conflicts or event logging,
cannot grant `R4`, and contributes zero score. A receipt does nothing
unless the exact local gate explicitly validates it.

---

## Capacity planning

These are order-of-magnitude expectations, not benchmarks. The Crystal
runtime is single-threaded and Sans-IO; the platform edge owns
concurrency.

- **Event log writes**: SQLite on a local disk sustains high-thousands
  of events per second; Postgres depends on network and server.
- **Event log reads**: replaying a 100k-event run is a bounded
  linear pass; plan for a few seconds on a cold start.
- **Storage**: roughly 1–2 KB per event including indexes; a
  million-event run is on the order of 1.5 GB.
- **Run concurrency**: one runtime per run; scale by running multiple
  runtimes, not by sharing one.

If your runs are big enough that any of this is a concern, the
single-process design is the next constraint you will hit.

---

## What this guide is not

This guide will not tell you how to set up Postgres, configure
Prometheus, or operate Grafana. Those are well-documented elsewhere and
the framework's integration with them is intentionally generic.

This guide will not recommend SLOs, alerts, or dashboards. Your
business context determines those. The metrics list above is the
foundation; what you build on top is yours.

This guide will not stay current with every release. The locked
contracts — log schema, metric names, status shape — will. Examples may
drift; the contracts will not.
