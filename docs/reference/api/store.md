# Store

Event stores, URL parsing, graph stores, and migration. For the
conceptual model see
[`docs/architecture.md`](../../architecture.md) (graph as projection of
the event log) and [`src/chronicle/replay.cr`](../../../src/chronicle/replay.cr).

## Stores

### `Chronicle::EventStore`

Abstract interface for durable event storage. The store is the
sequencing authority: the persisted copy's `sequence` is the
store-assigned, strictly-increasing append position, regardless of the
emitter's provisional value.

```crystal
abstract class EventStore
  abstract def append(event : Event) : Nil
  abstract def iter_events(after : String? = nil, before : String? = nil) : Array(Event)
  abstract def get_event(id : String) : Event?
  abstract def count : Int64
  abstract def truncate_after(event_id : String) : Nil
  abstract def close : Nil
end
```

### `Chronicle::MemoryEventStore`

Volatile, in-process store for tests and lightweight use.

### `Chronicle::SQLiteEventStore`

Durable SQLite-backed store (WAL + `synchronous=NORMAL`). Constructor
`(db_path : String, run_id : String)`; `:memory:` is supported. Adds a
file-level schema for `events`, `runs`, `meta`, plus the v1.5
compaction tier (`events_archive`, `snapshots`).

| Method | Signature |
| --- | --- |
| `.ensure_schema` | `(conn : DB::Database) -> Nil` |
| `.list_runs` | `(url : String) -> Array(RunRecord)` |
| `.most_recent_run_id` | `(url : String) -> String?` |
| `.fork_run` | `(url : String, *, parent_run_id, new_run_id, at_event_id, label, created_at) -> Int32` |
| `.migrate_run` | `(dst, rec, events) -> Int32` |
| `#seq_of` | `(event_id : String) -> Int64` |
| `#get_run` | `-> RunRecord?` |
| `#upsert_run` | `(created_at : String, ...) -> ...` |

`SQLiteEventStore::RunRecord` is the lineage record (`run_id`,
`parent_run_id`, `forked_at_event_id`, `label`, `created_at`).

### `Chronicle::PostgresEventStore`

PostgreSQL-backed store using the direct `pg` shard. Bootstrap uses
`BIGSERIAL`, `JSONB`, and `TIMESTAMPTZ`; it preserves the byte-stable
event payload alongside JSONB for native queryability. Constructor
`(url : String, run_id : String)`.

## Graph stores

The materialized graph projection (objects, relations, patches) lives
behind a `GraphStore`, distinct from the durable `EventStore` above.
Losing a `GraphStore` is recoverable by replay; losing the
`EventStore` is not.

### `Chronicle::GraphStore`

Abstract backend. `put_*` is an upsert by id; `get_*` returns nil for
unknown ids; `remove_*` is a no-op for unknown ids.

```crystal
abstract class GraphStore
  abstract def put_object(obj : GraphObject) : Nil
  abstract def get_object(object_id : String) : GraphObject?
  abstract def remove_object(object_id : String) : Nil
  abstract def all_objects : Array(GraphObject)
  abstract def put_relation(rel : GraphRelation) : Nil
  abstract def get_relation(relation_id : String) : GraphRelation?
  abstract def remove_relation(relation_id : String) : Nil
  abstract def all_relations : Array(GraphRelation)
  abstract def put_patch(patch : Patch) : Nil
  abstract def get_patch(patch_id : String) : Patch?
  abstract def all_patches : Array(Patch)
  abstract def remove_patch(patch_id : String) : Nil
end
```

Default query hooks: `find_objects(type)`, `find_objects_in_types`,
`find_relations(source, target, type)`, `neighborhood(object_id, depth)`,
and `match_chain(node_types, rels)`.

### `Chronicle::InMemoryGraphStore`

Volatile, dict-backed default backend.

### `Chronicle::PostgresGraphStore`

Namespaced PostgreSQL backend that pushes type, multi-type, relation, and
breadth-first neighborhood queries into indexed SQL; `match_chain`
composes the pushed-down hooks.

### `Chronicle::FalkorDBGraphStore`

FalkorDB backend that owns a small dependency-free RESP client and a
server-configured Cypher adapter. It stores objects as `:AGNode:AGObject`,
relations as native `:AGRelation` edges, and dangling endpoints as
placeholders. Requires an explicit server URL (no embedded fallback).

### `Chronicle::SQLiteGraphStore`

SQLite-backed graph projection.

## URL parsing + helpers

### `Chronicle.parse_store_url`

`(url : String) -> StoreURL`, raising `InvalidStoreURL` with a helpful
message. Schemes: `sqlite:///relative`, `sqlite:////absolute`,
`postgres://`, `postgresql://`. Bare filesystem paths are rejected.

### `Chronicle.open_store`

`(url : String, run_id : String) -> EventStore`. Dispatches explicitly to
`SQLiteEventStore` or `PostgresEventStore`.

### `Chronicle::StoreURL`

`scheme`, `raw`, optional `sqlite_path`.

## Migration

### `Chronicle::Migration`

Cross-store migration (CONTRACT v0.8 #5): copy every run (lineage +
events) from a source store into a destination store. Each run migrates
in a single destination transaction; writes are idempotent against
`UNIQUE(id, run_id)`. The ported path is SQLite → SQLite.

```crystal
report = Chronicle::Migration.migrate(
  "sqlite:///source.db",
  "sqlite:///dest.db",
  only_run_ids: ["run_1"]?,
)
report.ok?       # nothing failed (skips are fine)
report.failures  # runs needing attention
```

| Type | Fields |
| --- | --- |
| `Migration::RunReport` | `run_id`, `status` (`"ok"`/`"skipped"`/`"failed"`), `events_migrated`, `error?`, `skipped_events` |
| `Migration::Report` | `source_url`, `dest_url`, `runs`, `ok?`, `failures` |

> Divergence: upstream also ships `MigrationReport` /
> `MigrationRunReport` / `RunRecord` classes and a `skip_corrupted`
> recovery flag. Chronicle maps these to `Migration::Report` /
> `Migration::RunReport` / `SQLiteEventStore::RunRecord`;
> `skip_corrupted` is not yet ported and raises
> `IncompatibleRuntimeState`. Postgres migration is deferred. See
> [`plans/parity.md`](../../../plans/parity.md).
