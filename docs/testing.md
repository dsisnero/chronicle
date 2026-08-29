# Testing

Run the test suite with:

```bash
make test
```

Before submitting a change, also run `make format-check` and `make lint`.

## Discipline

- The suite is deterministic and runs offline. No live network calls, no
  live LLM/tool providers: model and tool behavior comes from mocks and
  recorded fixtures.
- Specs are ported from the upstream activegraph `tests/` where available
  (e.g. `test_graph.py`, `test_pattern_parser.py`, `graph_conformance.py`,
  `store/conformance.py`) and adapted to Crystal; the port is pinned by
  `plans/parity.md`.
- Reusable contract suites exist for backends: `spec/chronicle/graph_store_conformance.cr`
  (any `GraphStore`) and `spec/chronicle/event_store_conformance.cr` (any
  `EventStore`) — new backends get full coverage by invoking the mixin.
- A source-policy spec (`spec/core_io_safety_spec.cr`) keeps the core
  Sans-IO: it must not reference direct I/O, environment access, or process
  capabilities (time and randomness are permitted; only routing must be
  deterministic).

## Interactive specs

`spec/chronicle/cli_chat_integration_spec.cr` includes the single
TTY-launching example. It is tagged `interactive`, so `make test` excludes it
and always runs headlessly. Run it explicitly in a terminal when exercising
the live chat loop:

```bash
make test-interactive
```

When running Crystal directly, exclude interactive specs with:

```bash
crystal spec -- --tag ~interactive
```

## FalkorDB integration

On macOS, run the live FalkorDB graph-store conformance suite with Apple's
`container` CLI:

```bash
make test-falkordb
```

The target starts an authenticated disposable `falkordb/falkordb` container,
waits for Redis readiness, then runs the opt-in specs in a Crystal container on
the same private Apple Container network. It does not publish a host port, so
the gate also works on hosts where VM port forwarding is unavailable. Both the
server and its temporary network are removed when the suite exits. The Crystal
client uses the server's inspected private address and installs its SQLite
development library before compiling the spec.
Override
`FALKORDB_PASSWORD`, `FALKORDB_IMAGE`, or `FALKORDB_TEST_IMAGE` only when the
local environment requires it. The disposable server and spec client default
to 2G and 4G respectively; override `FALKORDB_SERVER_MEMORY` or
`FALKORDB_TEST_MEMORY` on smaller hosts.
