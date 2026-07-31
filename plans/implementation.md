# Implementation Plan: Log-Primary Sans-IO Agent Runtime

## Purpose

Build Clarity as a Crystal agent-runtime library whose execution history is an
append-only event log. The runtime derives graph state from that log, applies
deterministic and explainable routing before any model call, and keeps network
and operating-system effects at the edge.

This plan adapts the event-sourced, reactive-graph ideas in
[The Log is the Agent](https://arxiv.org/html/2605.21997v1) and the
local-first, versionable-policy approach of
[smista.ai](https://github.com/smista-ai/smista.ai). They are design inputs,
not dependencies or claims that Clarity implements either project.

## Outcomes and Non-Goals

### Outcomes

- Strict replay produces the same projection and routing decisions for a
  recorded log, without issuing model, tool, or network calls.
- A route can be previewed without spending tokens or performing side effects.
- Every model selection, excluded context item, permission check, approval, and
  effect result has an auditable causal event.
- Protocol parsers and the agent core are Sans-IO: neither opens sockets,
  reads files, spawns fibers, or runs shell commands.
- Runs can fork at an event boundary and structurally compare their graph
  projections.

### Non-Goals for the First Release

- Reproducing a live LLM response by sampling it again. Live responses are
  recorded; replay serves those recorded results.
- A workflow DSL or a central imperative orchestrator.
- A generic HTTP server, provider SDK, database, or distributed scheduler.

## Architectural Boundaries

```text
Crystal platform edge (sockets, fibers, filesystem, provider/tool adapters)
  ↕ bytes / effect results
Sans-IO protocol adapters (incremental parsing and serialization; no sockets)
  ↕ typed ingress events / effect requests
Log-primary core (event store, projection, router, behaviors, runner)
```

The platform edge owns real I/O and turns every observed result into an event.
Protocol adapters may retain parser state such as incomplete frame bytes, but
never a socket or other system capability. The core accepts events and emits
effect requests; it never executes them.

Use [dsisnero/cml](https://github.com/dsisnero/cml) at this platform edge for
fiber coordination only. Compose socket reads, approved effect results,
shutdown, cancellation, and deadlines with CML events, then pass the selected
result to one sequencer that assigns its log sequence and causal metadata.
Never place `CML::Event`, `CML::Chan`, timeout reads, or `choose` outcomes in
the core API or persisted log: live readiness is nondeterministic. Persist the
resulting typed ingress event instead.

## Core Contracts

### Event log and graph projection

Each event has a schema version, monotonic sequence, stable ID, type, actor,
`caused_by` event ID, canonical payload bytes, and recorded timestamp. The
projection is a pure fold of this ordered log into typed graph objects and
relations. External code never mutates a projection directly.

Record request and response events for every model and tool effect. Normalize
and hash model requests from the complete effective request: messages, model,
parameters, tool definitions, output schema, and selected context. Hash tool
requests from the tool name and canonical arguments. Those hashes identify the
recorded response used during replay.

Provide two explicit modes:

- **Permissive replay** reprojects an existing log and uses recorded effect
  results when hashes match; a changed request starts a new branch.
- **Strict replay** compares the newly emitted event stream with the recorded
  stream and reports the first divergence.

Routing is the deterministic part of the core; the core is Sans-IO. It must
not open sockets, read files, read environment values, spawn processes, or
obtain other system capabilities directly — the boundary records those inputs
in events before the core consumes them. Time and randomness (e.g. run-id
ULIDs) may be used in the core; only routing must stay a pure function.

### Deterministic router

Routing is a pure function of a versioned policy, normalized request, workspace
snapshot, provider availability snapshot, and context inventory. It returns a
`RouteDecision` plus an ordered trace; it never asks an LLM to choose a route.

Evaluate one fixed pipeline:

1. Validate explicit command and model overrides against policy.
2. Classify intent with ordered, versioned rules and record the matching rule.
3. Select the route by priority, then specificity, then declaration order.
4. Apply privacy and tool-permission rules before context serialization.
5. Select minimum required context by stable score and tie-breakers, enforcing
   token and cost budgets; record every inclusion and exclusion.
6. Resolve only eligible provider/model fallbacks in declared order.
7. Return a previewable decision containing chosen target, matched rule,
   overrides/fallbacks, permissions, selected/excluded context, and cost range.

Classify constrained context as either required or discardable. Required
restricted context makes remote targets ineligible—including an explicit remote
override—and must fit the token budget or fail deterministically. Discardable
restricted context is excluded from remote prompts and recorded in the route
trace.

Route decisions are first-class events. A direct/local route produces an effect
request without a model request; a remote route produces a content-addressed
model request only after its privacy and permission checks pass.

### Agent runner and behaviors

Behaviors subscribe to typed events and graph predicates, then emit events or
effect requests. The runner processes an immutable work queue in deterministic
order: triggering event sequence, behavior priority, behavior ID, then emitted
event order. It records behavior start, completion, failure, retry, and
suppression events.

Use explicit limits for recursion depth, retries, fan-out, and pending effects.
Deduplicate idempotent effect requests by request hash. The platform edge
executes approved requests and feeds the resulting event back into the runner;
this is how the agent continues running without leaking I/O into the core.

Forking copies an event-log prefix by reference, creates a new branch identity
at a chosen sequence, and executes only the divergent suffix. Structural diff
compares projected objects, relations, and patches—not opaque serialized state.

## Delivery Plan

### Phase 0 — Contracts and fixtures

- [x] Define a versioned event envelope with a monotonic sequence, stable ID,
  causal ID, recorded timestamp, validated JSON payload, and canonical JSON
  encoding.
- [x] Enforce append-only ordering and unique event IDs in in-memory storage.
- [x] Write initial invariants for event ordering, ID uniqueness, payload
  validity, and canonical serialization (the event log is append-only; the
  graph projection is mutable state written through a GraphStore, following
  activegraph semantics).
- [x] Define a reusable canonical-content SHA-256 primitive and dedicated
  domain error types for invalid events, ordering, duplicate IDs, and causality.
- [x] Create replay fixtures that include successful model and failed tool
  effects in causal order.
- [x] Add a causal-parent invariant for events appended to the log.
- [x] Add a source-policy invariant that prohibits direct I/O, environment
  access, and process capabilities in the core (Sans-IO; time/randomness
  permitted — only routing must stay deterministic).

### Phase 1 — Deterministic routing

- [x] Implement policy/config types, ordered intent classification, route
  matching, privacy filtering, context budgeting, permission narrowing, and
  provider fallback resolution.
- [x] Implement pure `route preview` through `Routing::Router#preview`; it
  returns a decision and performs no model or tool execution.
- [x] Emit decision traces with selected rule, classification source,
  precedence rationale, excluded context, required permissions, and a cost
  range.
- [x] Add deterministic tests for override, priority, specificity,
  declaration-order ties, restricted context, unavailable targets, budget
  overflow, and no-route behavior.

### Phase 2 — Log, projection, and agent runner

- [x] Implement append-only in-memory storage and an initial pure run-state
  fold for `goal.created` events.
- [x] Extend the projection to typed graph objects and relations, including
  object patches and structural diffs.
- [x] Implement behavior subscription evaluation, deterministic queue ordering,
  lifecycle records, and bounded fan-out/pending effects.
- [x] Model effects as requests and recorded results; add strict/permissive
  replay with first-divergence reporting.
- [x] Implement branch creation from an event-log prefix and structural graph
  diffs between parent and fork projections.

### Phase 3 — Sans-IO transports and edge adapters

- [x] Implement an initial incremental HTTP/1.1 request-framing adapter and
  deterministic request serialization behind typed Sans-IO ingress and egress
  APIs.
- [x] Add a CML-based platform edge that composes socket, effect-result,
  approval, cancellation, and timeout signals. A single sequencer wraps each
  selected signal as a typed ingress envelope before it reaches the core.
- [x] Keep CML channels/events and socket/process/provider concerns in the
  designated platform-edge adapter; policy specs forbid CML in core modules.
- [x] Add an approval adapter for file writes, shell commands, network access,
  and restricted-context disclosure.

### Phase 3a — HTTP/1 conformance

- [x] Replace the initial request-only adapter with a complete Sans-IO HTTP/1
  connection state machine for requests and responses. Keep all socket and
  timer ownership at the platform edge.
- [x] Adopt focused, normalized MIT-licensed h11 conformance fixtures for
  incremental headers, content-length framing, chunked bodies and trailers,
  pipelining, no-body responses, and malformed framing. Each copied or adapted
  case records upstream path, commit, test name, and license attribution.
- [x] Reject ambiguous or unsafe framing deterministically: invalid start
  lines/header syntax, unsupported transfer codings, conflicting
  Content-Length values, and Transfer-Encoding plus Content-Length.
- [x] Define a pure, token-aware connection-persistence policy: HTTP/1.1 is
  persistent unless `Connection` includes `close`; HTTP/1.0 is close by
  default.
- [x] Support HTTP/1.0 and HTTP/1.1 connection persistence, EOF-delimited
  response bodies, informational responses, HEAD/CONNECT/upgrade body rules,
  configured incomplete-message and header limits, and deterministic outbound
  serialization.
- [x] Add a non-vendored fixture-import/check script pinned to h11's upstream
  commit. Keep GPL fuzz projects, including HTTP Garden, outside this source
  tree and run them only as external differential/security harnesses.

### Phase 4 — Operational hardening

- [x] Persist versioned event logs through a pure, newline-delimited codec with
  explicit format versioning and canonical round-trip checks.
- [x] Add content-addressed effect artifacts: `EffectArtifactStore` indexes
  effect requests and results by SHA-256 payload hash. During replay, the
  store supplies recorded results without parsing `effect.responded` events.
  Deduplication is automatic (same payload → same hash → idempotent store).
- [x] Add trace export via `tracing.cr`: `Clarity::Telemetry` emits structured
  `route.preview` spans with decision attributes.
- [x] Add `log inspect` CLI: read and display events from a persisted log file.
- [x] Add `replay` CLI: replay a log file and show reconstructed graph state.
- [x] Add `diff` CLI: compare two event logs and show structural diffs.
- [x] Add `route preview` CLI: preview a routing decision without executing.
- Add fork CLI surface.
- Measure routing bypass rate, token/cost avoided, replay divergence rate,
  queue latency, and effect failure rate with recorded fixtures.

## Adopted Routing Rule Schema (from smista.ai)

The following routing rule fields and precedence rules are adopted from
[smista.ai](https://github.com/smista-ai/smista.ai) and recorded here so that
deterministic tests can reference them. DeepWiki guidance was consulted;
the pinned source at `crates/smista-core/src/policy/routing.rs` and
`crates/smista-router/src/router/resolver/policy_matcher.rs` is the
conformance reference.

### RouteRule fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `String` | required | Human-readable rule name |
| `priority` | `Int32` | `1000` | Evaluation order (lower = higher priority) |
| `intent` | `Intent?` | `nil` | Required task intent |
| `paths` | `Array(String)` | `[]` | File-path glob patterns (OR across globs) |
| `local_only` | `Bool` | `false` | Restrict fallback chain to local models |
| `model` | `String` | required | Primary model reference (`provider/model`) |
| `fallbacks` | `Array(String)` | `[]` | Fallback chain when primary is unavailable |
| `required_permissions` | `Hash(String, PermissionMode)` | `{}` | Tool permissions the route requires |
| `cost_limit` | `Float64?` | `nil` | Per-task cost ceiling |

### Precedence ladder (tie-breaking)

1. **Explicit model override** — `request.explicit_target` bypasses all rules.
2. **Priority** — lower `priority` value wins (default: `1000`).
3. **Specificity** — `PathIntent` (3) > `Path` (2) > `Intent` (1) > `Default` (0).
   Path + intent is more specific than either alone.
4. **Declaration order** — earlier rule in the config wins.

### Config format

Routing rules are loaded from a YAML file (mirroring smista's TOML structure)
using `YAML::Serializable`. Example:

```yaml
routing:
  default:
    model: openai/gpt-5.5-mini
    fallbacks:
      - ollama/qwen2.5-coder:7b
  rules:
    - name: review security-sensitive code locally
      priority: 5
      intent: review
      paths:
        - src/crypto/**
        - src/auth/**
      local_only: true
      model: ollama/qwen2.5-coder:7b
```

### Differences from smista.ai

Clarity omits `requires_capabilities` in the initial port. This can be
added when the model-selection and capability systems mature. Clarity
uses `Float64` for `cost_limit` instead of `rust_decimal::Decimal`.

Clarity's tool system follows activegraph's event-sourced pattern
(tool.requested/tool.responded events, ToolCache by content hash) with
Crig's ToolDyn/ToolServer at the platform edge for execution, rather
than smista's client-mediated tool dispatch. Permission checking via
`Routing::PermissionMode` is ported and available for tool gating.

## Acceptance Gates

- Identical logs yield byte-identical canonical projections in strict replay.
- Strict replay makes no live provider or tool calls.
- The same routing input and policy yields the same route and ordered trace.
- A route preview performs no side effects and spends no model tokens.
- Restricted context is absent from the serialized remote request and recorded
  as excluded in the route trace.
- Identical policy matches resolve by the documented precedence ladder.
- Runner scheduling is stable across repeated runs and failures are attributable
  to an event and behavior.
- A fork preserves prefix lineage and a structural diff isolates suffix changes.
- Sans-IO core and protocol tests run without live sockets or provider access.
- CML-edge tests prove cancellation cleanup and verify that only sequenced typed
  ingress events—not CML values or wall-clock reads—cross into the core.
- HTTP/1 conformance fixtures pass without live sockets and malformed framing
  cannot cause an ambiguous message boundary.

## Research References

- [Nakajima, *The Log is the Agent* (2026)](https://arxiv.org/html/2605.21997v1): log-primary state, deterministic projection, recorded effect replay, fork/diff, and behavior-based coordination.
- [smista.ai repository](https://github.com/smista-ai/smista.ai) and [routing configuration documentation](https://docs.smista.ai/configuration/cli.html): deterministic intent classification, policy precedence, least-context selection, route preview, and explainable traces.
- [Smista DeepWiki](https://deepwiki.com/smista-ai/smista.ai): consult before changing deterministic-routing semantics; validate any guidance against the pinned source/configuration and record the adopted rule in this plan.
- [h11 test suite](https://github.com/python-hyper/h11/tree/master/h11/tests)
  (MIT): primary Sans-IO HTTP/1 conformance reference. Import focused cases as
  attributed local fixtures rather than vendoring the implementation. The
  initial fixture set is pinned to `62c5068c971579d61fa1b55373390e12f25fd856`.
- [httparse](https://docs.rs/httparse) (MIT/Apache-2.0): supplemental
  request/response syntax and chunk-parser reference.
