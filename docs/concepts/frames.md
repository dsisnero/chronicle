# Frames

A frame is a bounded context for behavior dispatch. Events carry a
`frame_id`; behaviors can filter their subscription by `frame_id`; a run
can contain multiple frames running in parallel without their behaviors
crossing wires.

Frames are an optional primitive. Most uses of the framework don't need
them — a single-frame run is the default and covers every example in the
quickstart, the diligence pack, and the cookbook patterns. **If you're
not sure whether you need frames, you probably don't.** Use them when
you need to scope behavior dispatch beyond a single event-type filter.

## What frames are for

Three use cases where frames earn their weight:

- **Multi-tenant graph state.** One runtime, many tenants. Each tenant
  gets a frame; behaviors filter by `frame_id` to keep tenant A's events
  from triggering work on tenant B's data. Without frames, the same
  separation would require either a per-tenant runtime (heavy) or
  `where:` filters on every behavior (error-prone).
- **Parallel hypothesis exploration before fork is appropriate.** When
  the framework is reasoning about multiple hypotheses simultaneously
  and you want each to be a distinct context but don't yet want the fork
  primitive's cost (a fork is a separate run; frames are sub-contexts
  within one run). Useful for short-lived parallel reasoning that
  converges back to a single output.
- **Structured conversations.** When a long-running goal has multiple
  distinct sub-tasks, each with its own behavior dispatch logic, frames
  are the bounded-context primitive for the sub-task. Each sub-task's
  events stay in its own frame; the sub-task's behaviors filter on the
  `frame_id`.

## How frames scope dispatch

A frame is a `Chronicle::Frame` carrying a goal plus its guardrails:

```crystal
frame = Chronicle::Frame.new(
  goal: "Review tenant A's documents",
  constraints: ["read-only"],
  success_criteria: ["every claim has evidence"],
  permissions: ["filesystem.read"],
)

runtime.push_frame(frame)
runtime.run_goal("Review tenant A's documents")
runtime.pop_frame
```

The runtime's `current_frame_id` stamps every emitted event's
`frame_id`. A behavior that should only react within a frame filters on
`frame_id` in its `where:` clause:

```crystal
@[Behavior(
  name: "tenant_a_only",
  on: ["object.created"],
  where: {"frame_id" => "tenant_a"}
)]
def tenant_a_only(event : Chronicle::Event,
                  graph : Chronicle::GraphProjection,
                  ctx : Chronicle::Packs::BehaviorContext)
end
```

Without the filter, the behavior fires on events from every frame in the
run. The runtime doesn't auto-scope behaviors by frame — the explicit
filter is the contract.

Read a frame's events with `runtime.events_in_frame(frame_id)`. Frame
ids are strings, framework- or developer-generated. `Frame.new` with no
`id:` generates a monotonic `frame_N` id; developer-generated frames can
use semantically meaningful names (`tenant_a`, `hypothesis_left`,
`sub_task_42`).

## Relationship to runs

A run is the framework's top-level unit (one event log, one store
binding). A frame is a sub-context within a run.

- **One run, one frame** — the default. Every event in the run belongs
  to the same frame; behaviors don't need to filter by `frame_id`.
- **One run, many frames** — the use cases above. Events from different
  frames coexist in the same event log; behaviors that care about
  isolation filter explicitly.
- **Many runs, many frames** — also valid; each run's frames are
  independent. Common when multi-tenant systems shard tenants across
  multiple runs and also frame within each.

Frames don't cross runs. A frame is run-scoped — moving a frame between
runs would mean copying events, which is what fork and migrate are for.

## Frames vs forks

Both let parallel computations proceed in isolation. The difference is
durability and replay:

- **Fork** is a separate run with shared event-log lineage up to the
  fork point. Forks are durable and replayable independently. Use fork
  when the parallel branches might diverge permanently or need
  independent persistence.
- **Frames** are sub-contexts within one run. The frame's events live in
  the same event log as everything else; replay is the whole run. Use
  frames when the parallel contexts are short-lived or semantically
  belong together.

A common pattern is to start parallel work in frames and fork only the
branches that prove worth keeping. See [`forking`](forking.md) for the
fork primitive.

## What's related

- [`behaviors`](behaviors.md) — where `frame_id` filters appear in
  `where:`.
- [`events`](events.md) — events carry `frame_id`; the field is in the
  event structure.
- [`forking`](forking.md) — the durable parallel-context primitive;
  complements frames.
- [`replay`](replay.md) — frames replay as part of their run; there's no
  per-frame replay primitive.
