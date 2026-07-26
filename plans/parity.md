# ActiveGraph Parity Plan

Port core primitives and design patterns from
[yoheinakajima/activegraph](https://github.com/yoheinakajima/activegraph) —
the reference implementation of the event-sourced, reactive-graph design
described in [The Log is the Agent](https://arxiv.org/html/2605.21997v1).

## Source of Truth

- **Upstream**: https://github.com/yoheinakajima/activegraph (Python)
- **Design reference**: arXiv paper 2605.21997v1
- **DeepWiki**: https://deepwiki.com/yoheinakajima/activegraph

Before implementing any core logic change, consult activegraph's DeepWiki
for context on the relevant data structures and design decisions. Validate
DeepWiki guidance against the pinned upstream source. Record any divergence
from activegraph's design in this document.

## Primitives and Status

### Done (Clarity has a working equivalent)

| Primitive | Clarity | Notes |
|-----------|---------|-------|
| Event | `Clarity::Event` | schema_version, sequence, id, type, actor, caused_by, timestamp, payload |
| EventLog | `Clarity::EventLog` | Append-only, enforces sequence/causality invariants |
| Graph (projection) | `Clarity::GraphProjection` | Objects + relations folded from events |
| Object | `Clarity::GraphObject` | id, type, data |
| Relation | `Clarity::GraphRelation` | id, type, from_id, to_id |
| Diff | `Clarity::GraphDiff` | Added/removed objects and relations |
| Event persistence | `Clarity::EventLogCodec` | Newline-delimited JSON with format header |
| Replay | `Clarity::ReplayEngine` | Strict and permissive modes |
| Behavior runner | `Clarity::BehaviorRunner` | Event subscription, priority ordering, fan-out limits |
| Effect artifacts | `Clarity::EffectArtifactStore` | Content-addressed by SHA-256 payload hash |
| Fork | `EventLog#fork_at` | Copies event prefix up to sequence point |
| Session store | `Clarity::SessionStore` | Persist/load event logs to `~/.clarity/sessions/` |
| Trace export | `Clarity::Telemetry` | Structured tracing spans via `tracing.cr` |

### Missing — High Priority

#### 1. Deterministic Clock

ActiveGraph injects a deterministic `Clock` into behaviors. During replay
the clock is "frozen" — it returns timestamps from the replayed event log
instead of wall-clock time. Behaviors call `ctx.clock.now()` instead of
`datetime.now()` (Python) or `Time.now` (Crystal).

**What needs to happen:**
- Define `Clarity::Clock` abstract class with `now : Time` method
- Implement `ReplayClock` seeded from event timestamps during replay
- Implement `WallClock` for live execution
- Add `clock` to `BehaviorRegistration` context or make it injectable
- Verify replay determinism: same log → same `clock.now()` sequence

**DeepWiki consultation:** Before designing the clock interface, consult
activegraph's `activegraph/core/clock.py` and the `CONTRACT.md` section
on determinism.

#### 2. LLM Replay Cache

ActiveGraph's LLM cache avoids redundant API calls during fork and replay.
It stores LLM responses keyed by `sha256(canonical_json(model, system,
messages, params))`. During a fork, the cache is pre-populated from the
parent run's `llm.responded` events; matching request hashes serve the
cached response without calling the API.

**What needs to happen:**
- Define `Clarity::LLMCache` keyed by content hash (already partially
  covered by `EffectArtifactStore`)
- Populate cache from `EffectRequest`/`EffectResult` pairs during session
  load or fork
- In `ReplayEngine.replay()`, serve results from cache when request hash
  matches a recorded response
- Raise `ReplayDivergenceError` when strict replay encounters a hash
  mismatch (already supported)
- Add `replay_llm_cache: true` flag to `Runtime.load()` equivalent

**DeepWiki consultation:** Before implementing cache key structure,
consult activegraph's approach to canonical LLM request serialization
and the `prompt_hash` field on `llm.requested` events.

#### 3. Patches (Optimistic Concurrency)

ActiveGraph uses a `Patch` lifecycle (`proposed → applied | rejected`)
with `expected_version` to prevent two behaviors from silently
overwriting each other's mutations.

**What needs to happen:**
- Add `Patch` struct with fields: id, object_id, expected_version, data,
  status (proposed/applied/rejected), rejection_reason
- Add `PatchState` enum: Proposed, Applied, Rejected
- Add `version : Int64` to `GraphObject`, incremented on each applied
  patch
- Add event types: `patch.proposed`, `patch.applied`, `patch.rejected`
- Implement `GraphProjection#propose_patch`, `#apply_patch`, `#reject_patch`
- Version check on apply: reject if `current_version != expected_version`
- Enforce one-shot lifecycle: proposed → applied or rejected, no cycling
- Add behavior context method for safe object mutation via patches

**DeepWiki consultation:** Before designing the patch lifecycle, consult
activegraph's `activegraph/core/patch.py`, `activegraph/core/graph.py`
(`propose_patch`, `apply_patch`, `reject_patch`), and the `CONTRACT.md`
section on optimistic concurrency.

### Missing — Medium Priority

#### 4. Views (Scoped Graph Subsets)

ActiveGraph views provide scoped read-only projections for behaviors.
A behavior declares what it needs (`around`, `depth`, `include_types`,
`recent_events`), and the runtime constructs the view before invocation.

**What needs to happen:**
- Define `View` struct with configurable scope (path, depth, types, event
  window)
- Implement view construction from `GraphProjection` filtering by scope
- Wire view injection into behavior execution context
- Add decorator or metadata for behaviors to declare their view

**DeepWiki consultation:** Before designing the view system, consult
activegraph's `activegraph/core/view.py` and the view-related sections
of `CONTRACT.md`.

#### 5. Frames (Event Grouping)

ActiveGraph frames group related events within a run. The `frame_id`
field on events enables the runtime to track causality and manage
bounded sub-contexts. Frames differ from forks: frames are parallel
sub-contexts within one event log; forks are independent branch copies.

**What needs to happen:**
- Add `frame_id : String` field to `Event`
- Define `Frame` struct with id, goal, constraints, budget, behaviors
- Add `Runtime#push_frame` / `Runtime#pop_frame` for frame lifecycle
- Group events by `frame_id` in log inspection and trace export

**DeepWiki consultation:** Before implementing frames, consult
activegraph's frame lifecycle in `activegraph/runtime/runtime.py` and
the `CONTRACT.md` section on frame boundaries.

## Delivery Order

1. **Clock** — foundation for replay determinism
2. **LLM Replay Cache** — avoids redundant API calls, makes fork cheap
3. **Patches** — prevents data races, enables safe concurrent behaviors
4. **Views** — efficient scoped reads for behaviors
5. **Frames** — bounded sub-contexts within a run

Each item should be developed with red-green TDD. Before writing code for
any item, consult activegraph's DeepWiki for the relevant module, then
validate against the pinned source. Record any intentional divergence
from activegraph's design in this document with rationale.

## Acceptance Gates

- Same event log → same `clock.now()` sequence during replay
- LLM cache serves recorded responses for matching content hashes
- Cache miss during strict replay raises `ReplayDivergenceError`
- `patch.proposed` with `expected_version` rejects on version mismatch
- Patch one-shot invariant: proposed → applied/rejected, no cycling
- View returns only objects/relations matching its declared scope
- `frame_id` is preserved on events and visible in log inspect
