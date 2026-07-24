# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- An explicit HTTP/1 Sans-IO conformance phase, backed by focused,
  attribution-preserving h11 fixtures rather than vendored upstream code.
- Safer incremental HTTP request framing: chunked bodies and trailers,
  pipelining, HTTP/1.0 recognition, and rejection of ambiguous body framing.
- Incremental Sans-IO HTTP response framing for content-length, chunked, and
  EOF-delimited bodies, including status-driven no-body responses.
- A pure h11-aligned HTTP connection-persistence policy with case-insensitive,
  token-aware `Connection: close` handling.
- A role-aware Sans-IO HTTP/1 connection state machine covering request and
  response pipelining, informational responses, HEAD framing, protocol upgrade
  and CONNECT transitions, trailing protocol bytes, EOF failures, and bounded
  incomplete input.
- Deterministic HTTP response serialization and a `make http-fixtures` gate
  that verifies the pinned h11 fixture provenance without vendoring h11.
- Project development scaffolding, quality gates, and contributor guidance.
- An implementation plan for a log-primary, Sans-IO agent runtime with
  deterministic routing and CML-based platform-edge coordination.
- The `cml` shard dependency and its locked transitive dependencies.
- `Clarity::Event`, an immutable event envelope carrying boundary-supplied
  replay metadata.
- Validation that event payloads are valid JSON before they can be persisted in
  canonical event envelopes.
- Byte-stable canonical JSON encoding for event envelopes, with field ordering
  and raw canonical payload preservation covered by specs.
- A reusable canonical-content SHA-256 primitive and `Event#content_hash`.
- Domain-specific event errors for invalid payloads, ordering, duplicate IDs,
  and missing causal parents.
- Replay fixtures covering successful model and failed tool effects, plus a
  source-policy test that prevents direct I/O capabilities in the core.
- Deterministic routing policy evaluation with ordered intent classification,
  precedence rules, privacy filtering, context budgeting, permission
  narrowing, target fallback, cost estimates, and explainable route previews.
- Required restricted context now forces local-only target eligibility and is
  never trimmed; discardable restricted context is excluded from remote prompts.
- Typed graph projection and structural diffs over object and relation events.
- Deterministic behavior scheduling with lifecycle records and bounded effect
  fan-out.
- Recorded effect replay in permissive and strict modes, with divergence
  reporting and event-log forks.
- Incremental Sans-IO HTTP framing and deterministic request serialization.
- CML-composed platform-edge signals sequenced into typed ingress envelopes.
- Approval mediation for file writes, shell commands, network, and restricted
  context disclosure.
- `Clarity::EventLog`, in-memory append-only event storage that rejects
  non-increasing event sequences, duplicate IDs, missing causal parents, and
  returns defensive snapshots to callers.
- `Clarity::RunProjection`, a pure fold that derives the current objective from
  ordered `goal.created` events without mutating prior projections.
