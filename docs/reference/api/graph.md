# Graph

The graph and its primitives — objects, relations, patches, views,
and events. The graph is a projection of the event log; mutations
go through events. For the conceptual model see
[`docs/architecture.md`](../../architecture.md).

## `Chronicle::GraphProjection`

The projection is the write facade that owns the log + projection +
store and emits events. It is copy-on-write: `apply`/`patch` operations
produce independent snapshots.

```crystal
require "chronicle"

graph = Chronicle::GraphProjection.empty
graph = Chronicle::GraphProjection.replay(events)  # rebuild without firing behaviors
```

| Method | Signature |
| --- | --- |
| `.empty` | `-> GraphProjection` |
| `.replay` | `(events : Array(Event)) -> GraphProjection` |
| `#replayed_ids` | `-> Set(String)` |
| `#all_objects` | `-> Array(GraphObject)` |
| `#all_relations` | `-> Array(GraphRelation)` |
| `#all_patches` | `-> Array(Patch)` |
| `#get_object` | `(id : String) -> GraphObject?` |
| `#get_relation` | `(id : String) -> GraphRelation?` |
| `#get_patch` | `(id : String) -> Patch?` |
| `#objects` | `(type : String? = nil, where : Hash(String, JSON::Any)? = nil) -> Array(GraphObject)` |
| `#query` | `(object_type : String? = nil, where : Hash(String, JSON::Any)? = nil) -> Array(GraphObject)` |
| `#relations` | `(source : String? = nil, target : String? = nil, type : String? = nil) -> Array(GraphRelation)` |
| `#get_relations` | `(object_id : String? = nil, type : String? = nil, direction : String = "both") -> Array(GraphRelation)` |
| `#objects_in_types` | `(types : Array(String)) -> Array(GraphObject)` |
| `#has_object_of_type` | `(type : String) -> Bool` |
| `#neighborhood` | `(object_id : String, depth : Int32 = 1) -> {Array(GraphObject), Array(GraphRelation)}` |
| `#events` | `-> Array(Event)` |
| `#attach_store` | `(event_store : EventStore) -> GraphProjection` |
| `#add_listener` / `#remove_listener` | `(Proc(Event, Nil)) -> Nil` / `-> Bool` |

### Mutation

`graph.emit` is the single live mutation path, so `graph.events` is the
full run log. `add_object` / `add_relation` build the typed event and
emit it; `remove_*` cascade.

```crystal
graph = Chronicle::GraphProjection.empty
company = graph.add_object("company", %({"name":"Northwind"}), actor: "user")
graph.add_relation(company.id, other.id, "addresses")
graph.patch_object(company.id, %({"name":"Northwind Robotics"}))
```

| Method | Signature |
| --- | --- |
| `#apply` | `(event : Event) -> GraphProjection` |
| `#emit` | `(event : Event) -> Event` |
| `#emit` | `(type : String, payload : String, *, actor : String = "system", caused_by : String? = nil) -> Event` |
| `#add_object` | `(type : String, data : String, *, actor : String = "system", caused_by : String? = nil) -> GraphObject` |
| `#add_relation` | `(source : String, target : String, type : String, data : String = "{}", *, actor : String = "system", caused_by : String? = nil) -> GraphRelation` |
| `#remove_object` / `#remove_relation` | `(id : String, *, actor : String = "system", caused_by : String? = nil) -> Nil` |
| `#patch_object` | `(target : String, value : String, *, actor : String = "system", patch_id : String? = nil) -> PatchResult` |
| `#propose_patch` | `(target : String, op : String, value : String, *, proposed_by : String = "system", expected_version : Int64? = nil, patch_id : String? = nil) -> Patch` |
| `#apply_patch` / `#reject_patch` | `(patch_id : String) -> GraphProjection` / `(patch_id : String, reason : String) -> GraphProjection` |
| `#match_chain` | `(node_types : Array(String?), rels : Array({String, String})) -> Array(ChainMatch)` |
| `#build_view` | `(spec : ViewSpec = ViewSpec.new) -> View` |

### Sinks

`GraphProjection` accepts bounded outbound observers. See
[Observability](observability.md).

| Method | Signature |
| --- | --- |
| `#add_sink` | `(sink : Sink, name : String? = nil, queue_capacity : Int32 = 1024, overflow_policy : OverflowPolicy = OverflowPolicy::DropNewest) -> String` |
| `#remove_sink` | `(name : String) -> Nil` |
| `#flush_sinks` | `-> Nil` |
| `#sink_statuses` | `-> Hash(String, SinkStatus)` |
| `#close_sinks` | `-> Nil` |

## Primitives

### `Chronicle::Event`

Immutable input to the log projection. `payload` is a canonical JSON
string; `canonical_json` and `content_hash` provide the byte-stable
envelope used for persistence and hashing.

| Field | Type |
| --- | --- |
| `schema_version` | `UInt16` |
| `sequence` | `UInt64` |
| `id` | `String` |
| `type` | `String` |
| `actor` | `String` |
| `caused_by` | `String?` |
| `frame_id` | `String?` |
| `timestamp` | `Time` |
| `payload` | `String` |

```crystal
event = Chronicle::Event.new(
  schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
  type: "goal.created", actor: "user",
  caused_by: nil, payload: %({"goal":"ship it"}),
)
```

### `Chronicle::GraphObject`

| Field | Type |
| --- | --- |
| `id`, `type`, `data` | `String` (`data` is raw canonical JSON) |
| `version` | `Int64` |
| `provenance` | `Provenance` |

### `Chronicle::GraphRelation`

`id`, `type`, `from_id`, `to_id` (`String`) and `provenance`
(`Provenance`).

### `Chronicle::Patch` / `PatchState` / `PatchOp`

`PatchOp` is `Create | Update | Replace | Remove`; `PatchState` is
`Proposed | Applied | Rejected`. `Patch` carries `id`, `target`, `op`,
`value`, `expected_version`, `proposed_by`, `status`, `rejection_reason`,
and optional `provenance`.

### `Chronicle::View` / `ViewSpec`

`View` is the rendered read model returned by `build_view`; `ViewSpec`
selects `include_types`, `around`, and `recent_events`.

## Diffs

Structural comparison lives in [`diff.cr`](../../../src/chronicle/diff.cr)
for run-to-run comparison and in `GraphProjection#diff` for
projection-to-projection comparison.

### `Chronicle::Diff`

| Field | Type |
| --- | --- |
| `parent_run_id`, `fork_run_id` | `String` |
| `shared_events`, `parent_only_events`, `fork_only_events` | `Array(Event)` |
| `divergent_objects` | `Array(DivergentObject)` |
| `divergent_relations` | `Array(DivergentRelation)` |
| `identical?` | `Bool` |

```crystal
diff = Chronicle::Diff.compute(
  parent, fork,
  parent_events: parent_events, fork_events: fork_events,
  parent_run_id: "parent", fork_run_id: "fork",
)
diff.divergent_objects.each { |obj| puts obj.summary }
```

### `Chronicle::DivergentObject` / `Chronicle::DivergentRelation`

Per-id provenance-stripped snapshots (`in_parent` / `in_fork`), each with
a `summary` string. Nil on the side where the id does not exist.

### `Chronicle::GraphDiff`

Returned by `GraphProjection#diff`; lists added and removed ids for
objects, relations, and patches.

> Divergence: upstream exposes a single `Diff` value. Chronicle keeps
> the `Diff`/`DivergentObject`/`DivergentRelation` trio for run-to-run
> comparison and adds `GraphDiff` for projection-to-projection
> comparison. See [`plans/parity.md`](../../../plans/parity.md).

## Promote

Three-way structural comparison between the parent at the fork point
(base), parent-now, and fork-now. Fork-only changes promote; both-sides
changes conflict (fail-closed, atomic).

### `Chronicle::PromotePlan`

| Field | Type |
| --- | --- |
| `from_run`, `into_run`, `forked_at_event`, `computed_against` | `String` |
| `object_creates`, `object_patches`, `relation_creates` | `Array(Hash(String, JSON::Any))` |
| `object_removes`, `relation_removes` | `Array(String)` |
| `conflicts` | `Array(PromoteConflict)` |
| `warnings` | `Array(String)` |
| `is_promotable`, `is_empty` | `Bool` |

### `Chronicle::PromoteResult`

The applied plan plus `marker_event_id` (the `promote.applied` event) and
`applied_event_ids`; `computed_against` delegates to the plan.

### `Chronicle::PromoteConflict`

`kind` is `both_changed | dangling_relation | orphaning_removal`; carries
`entity`, `id`, `detail`, and optional `in_base` / `in_parent` /
`in_fork` snapshots.

### `Chronicle::Promote` module

`Promote.compute_promote_plan(...)` returns a plan without applying;
`Runtime#promote(fork, dry_run:)` applies or dry-runs.
`Promote.promote_warnings(...)` lists pack/settings state promote never
transfers.
