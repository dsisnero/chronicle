# Observability

Accepted-event sinks, the metrics protocol, structured logging, trace,
and shipped backends. For the conceptual model see
[`docs/architecture.md`](../../architecture.md).

## Accepted-event sinks

Every return is ignored and every exception is isolated into sink status
and metrics, never into execution. The Sans-IO core enqueues into a
bounded FIFO; `flush_sinks` drains it (no worker threads).

### `Chronicle::Sink`

```crystal
abstract class Sink
  def open : Nil
  abstract def on_event(event : Event, context : DeliveryContext) : Nil
  def flush : Nil
  def close : Nil
end
```

### `Chronicle::DeliveryContext`

`run_id`, `sequence`, `mode` (default `"live"`).

### `Chronicle::SinkConfig`

Configuration for one isolated sink attachment: `sink`, optional `name`
(unique per runtime), `queue_capacity` (default `1024`), and
`overflow_policy` (default `DropNewest`).

### `Chronicle::OverflowPolicy`

`DropNewest` | `DropOldest` | `FailSink`.

### `Chronicle::SinkHandle`

One isolated attachment: a bounded FIFO with an overflow policy.
`offer(event)`, `flush`, `close`, `status : SinkStatus`.

### `Chronicle::SinkStatus`

`name`, `run_id`, `state`, `queue_capacity`, `queue_depth`, `enqueued`,
`delivered`, `dropped`, `errors`.

### `Chronicle::SinkState`

`Running` | `Closed` | `Failed`.

### Shipped sinks

| Class | Behavior |
| --- | --- |
| `Chronicle::JSONLSink` | Writes accepted events as newline-delimited canonical JSON. |
| `Chronicle::TestingSink` | Collects delivered `events` and `contexts` in memory. |
| `Chronicle::RaisingSink` | Always raises, used to prove sibling isolation. |

> Divergence: upstream ships `RecordingSink` + a `RecordedDelivery`
> value object. Chronicle's `TestingSink` fills that role and the
> per-attachment `SinkStatus` carries the delivery counters. See
> [`plans/parity.md`](../../../plans/parity.md).

### Adapter conformance

The reusable `SinkConformance` mixin lives at
`spec/chronicle/sink_conformance.cr`; future sink adapters include it and
supply the read/factory hooks.

## Metrics protocol

### `Chronicle::Metrics`

Three methods, all best-effort and non-throwing (CONTRACT v0.8 #8–#10).
Implementations must tolerate unknown metric names and tag keys.

```crystal
abstract class Metrics
  abstract def counter(
    name : String, tags : Hash(String, String), value : Float64 = 1.0,
  ) : Nil
  abstract def histogram(
    name : String, tags : Hash(String, String), value : Float64,
  ) : Nil
  abstract def gauge(
    name : String, tags : Hash(String, String), value : Float64,
  ) : Nil
end
```

The standard metric table is `Chronicle::MetricsTable::METRIC_NAMES`
(`Array(MetricSpec)`), with `MetricsTable.names`, `.by_name`, and
`.validate_cardinality_rule` (run_id is gauge-only). `MetricsError`
signals a table violation.

## Backends

### `Chronicle::NoOpMetrics`

Default: does nothing. The runtime is fully functional with it.

### `Chronicle::PrometheusMetrics`

In-memory `Metrics` implementation that records observations; `counters`,
`gauges`, `histogram_sums`, and `histogram_counts` are exposed.
`Chronicle::Prometheus.render(metrics, table = MetricsTable::METRIC_NAMES)`
emits the text exposition format (v0.0.4): `# HELP`/`# TYPE` from the
standard table, one sample line per label set, histograms as
`_sum`/`_count`/`+Inf` bucket.

The optional HTTP scrape edge is
`Chronicle::Prometheus::ScrapeServer` (`start`, `close`, `address`),
serving only `GET /metrics`. It is **not** part of the Sans-IO core.

### `Chronicle::OpenTelemetryMetrics`

Adapter over an application-owned `OpenTelemetry::Meter`; counters,
histograms, and gauges map to the matching synchronous instruments
(gauges as UpDownCounter deltas). The adapter owns neither trace context
nor exporter lifecycle.

> Divergence: upstream's OTel backend is a thin wrapper over the Python
> `opentelemetry-sdk`. Chronicle requires the `opentelemetry-sdk` shard
> and an application-owned meter. See
> [`plans/parity.md`](../../../plans/parity.md).

## Logging

### `Chronicle::Logging`

The Sans-IO structured-log formatting core. `LOG_FIELDS` is the
documented operator schema; actual I/O happens at the platform edge.

| Method | Signature |
| --- | --- |
| `.format_line` | `(*, timestamp, level, logger, message, extras) -> String` (one compact JSON line) |
| `.runtime_log_extra` | `(**fields) -> Hash(String, JSON::Any)` (drops nils, renames reserved keys with `ag_`) |
| `.set_payload_redactor` | `(Proc(Hash(String, JSON::Any), Hash(String, JSON::Any))?) -> Nil` |
| `.redact_payload` | `(payload) -> Hash(String, JSON::Any)` |

## Trace

### `Chronicle::Trace`

Causal-chain rendering over an event log.

| Method | Signature |
| --- | --- |
| `.causal_chain` | `(events : Array(Event), graph : GraphProjection, object_id : String) -> String` |
| `.format_event` | `(event : Event) -> String` |
| `.format_replay` / `.format_replay_complete` / `.format_replay_ready` | `(...) -> String` |
| `.prompt_normalized_rollup` | `(events, replayed_ids) -> {Bool, Int32}?` |
| `.format_trace_flags` | `(count : Int32) -> String` |

### `Chronicle::TraceFacade`

Read-only facade over a run's event log, exposed as `Runtime#trace`
(CONTRACT #18 trace lines). `#events`, `#failures`, and
`#lines(replayed_ids)`.
