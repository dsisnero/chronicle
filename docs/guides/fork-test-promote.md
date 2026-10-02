# Fork, test, promote

The runtime's self-modification loop: branch a run at an event, try a
candidate change in the branch against replayed history, and — if it
earns it — adopt the branch's results back into the parent. Every step
is a first-class runtime primitive:

1. **Fork** — `rt.fork(at_event: ...)` branches the run into an
   isolated child that shares the parent's history.
2. **Test** — the fork is a full `Runtime`: hot-load a candidate pack,
   run goals, let behaviors fire. The replay cache serves the shared
   prefix, so no LLM or tool call re-executes.
3. **Compare** — `rt.diff(fork)` shows the structural divergence.
4. **Promote** — `rt.promote(fork)` applies the fork's net delta to the
   parent, atomically, or refuses loudly (CONTRACT v1.3 #4).

The loop is domain-neutral physics. What a product builds on top —
approval gates before the promote, test thresholds a fork must pass,
retry policies — is the caller's layer; the runtime guarantees
isolation, honest comparison, and fail-closed adoption.

## The whole loop

```crystal
require "chronicle"

# `parent` is a SQLite-backed runtime; `agent` is the Crig agent for the
# model, `MyModel` a Crig::Completion::CompletionModel.
store = Chronicle::SQLiteEventStore.new("assistant.db", run_id: "parent")
parent = Chronicle::Runtime(MyModel).load("assistant.db", "parent", agent)

# 1. Fork at the tip (any event id works — inclusive cutoff).
fork = parent.fork(
  at_event: parent.trace.events.last.id,
  label: "candidate-behavior-test",
  replay_llm_cache: true,
  replay_tool_cache: true,
)

# 2. Test the candidate change in isolation.
fork.load_pack(CandidatePack::PACK)         # hot-load the new capability
fork.run_goal("exercise the change")        # or fork.run_until_idle
raise "candidate failed" unless fork.trace.failures.empty?

# 3. Inspect what the fork actually did.
plan = parent.promote(fork, dry_run: true).as(Chronicle::PromotePlan)
puts plan.object_creates
puts plan.object_patches
puts plan.warnings

# 4. Adopt it.
result = parent.promote(fork).as(Chronicle::PromoteResult)
puts "promoted as #{result.marker_event_id}"
```

```crystal
# The same loop over the encoded event logs, from the shell:
#   chronicle-cli fork -f parent.log -a <sequence> -o fork.log
#   ... run the fork ...
#   chronicle-cli diff -a parent.log -b fork.log
```

`fork` and `diff` are available as library primitives and as
`chronicle-cli` subcommands. Unlike upstream's URL-addressed CLI, the
Crystal CLI operates on encoded event-log files, and there is no
`promote` subcommand — `promote` is library-only. See
`plans/parity.md`.

## What promote applies — and what it refuses

Promote computes a **three-way structural comparison**: the parent's
state at the fork point (the base), the parent now, and the fork
now. Per entity (object or relation):

- changed **only in the fork** → promoted;
- changed **only in the parent** → left alone (the parent's own work);
- changed **on both sides** → conflict, and one conflict fails the
  whole promote with `PromoteConflictError` before anything is
  applied. There is no partial promote and no `force=` flag — identical
  concurrent edits conflict too (v1 makes no semantic judgments).

Referential integrity is part of the check: a promoted relation whose
endpoint the parent has since removed, or a promoted removal that would
cascade away relations the parent built after the fork, both conflict.

The recovery from a conflict is the loop itself: **fork again** from
the parent's current tip, re-apply the candidate change there (the
cache keeps it cheap), and promote the fresh fork — re-testing the
change against the parent's actual present.

Apply also validates the delta against the **parent's** loaded pack
schemas, pre-mutation: promoted objects whose type a parent pack
declares must satisfy that schema (`PackSchemaViolation` otherwise,
with nothing applied), and are stored canonicalized exactly as
`add_object` would store them; types no loaded pack declares pass
through untyped, the same v0.9 semantics as `add_object`. If your
adoption flow loads the candidate pack before promoting (the
recommended order: dry-run → `load_pack` → promote), the promoted
state is schema-checked against the very pack that defines it.

## What promote deliberately does not move

- **Pack loads and settings overrides.** Packs are code. A fork
  hot-loading `CandidatePack` does not entitle the parent to import it
  silently — the plan carries a warning, and adopting the pack is an
  explicit `parent.load_pack(...)`. This is the governance seam: gate
  *that* call behind whatever approval flow your product needs.
- **LLM/tool cache entries, lifecycle events, budget state, pending
  approvals** — per-run bookkeeping, not graph state.

## The audit trail

An applied promote is ordinary history. The parent's log gains one
`promote.applied` marker event (source run, fork point, id lists,
warnings) followed by the delta as plain `object.created` /
`patch.applied` / `relation.*` events with
`actor="promote:<fork-run>"`, each `caused_by` the marker:

```text
[promote.applied]         run_b -> here (+2 ~1) forked_at=evt_042
[object.created]          note#7 "test result"
[patch.applied]           task#1 status: open -> done
```

`Chronicle::Trace.causal_chain` walks any promoted entity back to the
marker; `Runtime.load` replays promoted state with no special cases;
the fork's full event history stays intact and queryable under its own
run id in the same store.

## Reacting to a promote

The delta is applied **quiescently** — behaviors do not fire per
promoted event, because the fork already processed those mutations
live and re-firing would duplicate their side effects. The one
reaction point is the marker:

```crystal
@[Behavior(name: "on_promote", on: ["promote.applied"])]
def on_promote(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
  payload = JSON.parse(event.payload).as_h
  # Fires once, after the full delta; post-promote state is visible.
  puts "adopted #{payload["objects_created"]?.try(&.as_a?.try(&.size))} " \
       "from #{payload["from_run"]?.try(&.as_s?)}"
end
```

## Timing and staleness

`dry_run: true` plans are advisory. Apply always recomputes against the
parent's current state, so a plan that was clean when you printed it
can conflict by the time you apply — the parent may have moved.
`plan.computed_against` (the parent tip event id the plan saw) makes
staleness detectable; a conflicted apply after a clean dry run means
exactly that. `plan.is_promotable` is the no-conflict check;
`plan.is_empty` reports an empty delta.

## Requirements

Both runtimes on the same SQLite store, and the source must be a
**direct fork** of the destination per the store's lineage records —
promote grandchild forks one level at a time (`PromoteLineageError`
names each rejection shape). The Crystal port's `promote` requires a
SQLite-backed parent and fork; Postgres-backed runs are not promotable
in this port (reference `plans/parity.md`).

## What's related

- [Authoring packs](authoring-packs.md) — building the candidate
  capability the fork tests.
- [Common patterns](../cookbook/common-patterns.md) — fork-and-diff
  idioms.
- [Debugging](../cookbook/debugging.md) — the trace is the first thing
  to read when a fork diverges.
