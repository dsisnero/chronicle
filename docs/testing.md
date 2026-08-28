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
