# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

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
- `Clarity::EventLog`, in-memory append-only event storage that rejects
  non-increasing event sequences, duplicate IDs, missing causal parents, and
  returns defensive snapshots to callers.
- `Clarity::RunProjection`, a pure fold that derives the current objective from
  ordered `goal.created` events without mutating prior projections.
