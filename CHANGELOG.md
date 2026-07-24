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
- Byte-stable canonical JSON encoding for event envelopes, with field ordering
  and raw canonical payload preservation covered by specs.
- `Clarity::EventLog`, in-memory append-only event storage that rejects
  non-increasing event sequences and returns defensive snapshots to callers.
