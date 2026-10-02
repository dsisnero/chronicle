# Chronicle

An event-sourced reactive graph runtime for long-running, auditable,
agentic systems. Behaviors react to events, mutate the graph, emit
more events. The event log is the source of truth — every run is
replayable, forkable, and diff-able from its log.

Chronicle is a Crystal port of
[activegraph](https://github.com/yoheinakajima/activegraph), the
reference implementation of the design in
["The Log is the Agent"](https://arxiv.org/html/2605.21997v1). The
concepts here are shared; the API is Crystal.

You're already past `shards install` and you want to know where to
start. **Run the framework first, read second.**

```bash
chronicle-cli quickstart
```

That runs the bundled Diligence pack on a scripted provider (no API
key, no network, under 30 seconds) and prints a memo. You'll see what
the framework does before you read about how it does it. The command
ends with a "what just happened" section pointing back here.

## Start here

- **[Quickstart](quickstart.md)** — from `require "chronicle"` to a
  working custom behavior. Every example maps to a runnable file under
  `examples/`. Reading this is the canonical first thing.
- **[Concepts: Failure model](concepts/failure-model.md)** — read this
  second. The framework's stance on what counts as a recoverable
  failure governs how every error message reads and how every behavior
  should be written. Short on its own; load-bearing across everything
  else.

## When something specific breaks

Errors are structured Crystal exceptions under
`Chronicle::ActiveGraphError`, and each carries a what-failed / why /
how-to-fix triple. The error reference catalog belongs under
`docs/reference/errors/` as it is ported. You should rarely need to
visit it directly; the error message that fired tells you which page.

## Contents

Get started:

- [Quickstart](quickstart.md)
- [Concepts: failure model](concepts/failure-model.md)

Concepts:

- [Events](concepts/events.md)
- [Graph](concepts/graph.md)
- [Relations](concepts/relations.md)
- [Behaviors](concepts/behaviors.md)
- [Views](concepts/views.md)
- [Patches](concepts/patches.md)
- [Patterns](concepts/patterns.md)
- [Policies](concepts/policies.md)
- [Frames](concepts/frames.md)
- [Replay](concepts/replay.md)
- [Forking](concepts/forking.md)
- [Failure model](concepts/failure-model.md)
- [Type system](concepts/type-system.md)

Guides:

- [Authoring packs](guides/authoring-packs.md)
- [Fork, test, promote](guides/fork-test-promote.md)
- [Operating in production](guides/operating-in-production.md)
- [Using FalkorDB](guides/using-falkordb.md)

Cookbook:

- [Common patterns](cookbook/common-patterns.md)
- [Debugging](cookbook/debugging.md)
- [Multi-run scripts](cookbook/multi-run-scripts.md)
- [Migration from v0.7](cookbook/migration-from-v0-7.md)

Reference:

- [CLI](reference/cli.md)
- [Errors](reference/errors.md)
- [LLM providers](reference/llm-providers.md)
- [Reason codes](reference/reason-codes.md)
- API: [index](reference/api/index.md), [graph](reference/api/graph.md),
  [runtime](reference/api/runtime.md),
  [behaviors](reference/api/behaviors.md),
  [packs](reference/api/packs.md), [store](reference/api/store.md),
  [tools](reference/api/tools.md),
  [observability](reference/api/observability.md),
  [sandbox](reference/api/sandbox.md), [errors](reference/api/errors.md)

Development:

- [Architecture](architecture.md) — the log-primary, Sans-IO architecture
  and module map.
- [Development](development.md)
- [Coding guidelines](coding-guidelines.md)
- [Testing](testing.md)
- [PR workflow](pr-workflow.md)
- [Parity plan](../plans/parity.md) — what is ported, what is deferred, and
  every intentional divergence from upstream.
- [Changelog](../CHANGELOG.md) — release history.

## Machine-readable docs

The repository itself is the machine-readable corpus: `docs/` holds the
concept, guide, cookbook, and reference pages in Markdown, and
`plans/parity.md` records the per-symbol parity ledger. Both are checked in
and diffable.

## Source and issues

- [GitHub repository](https://github.com/dsisnero/chronicle)
- [Upstream reference implementation](https://github.com/yoheinakajima/activegraph)
- [Changelog](../CHANGELOG.md) — release history.
