# Debugging

The framework's audit trail is the same artifact whether you're
investigating a production bug or developing a new behavior. The event
log records what happened; the trace renders it for human scanning;
`chronicle-cli log inspect` slices it for narrow questions; the fork
primitive lets you re-run with one variable changed to isolate cause.

This page is the diagnostic walkthrough: how to use the framework's
operator surface to answer the common debugging questions in order,
from "what just happened" to "why did it happen that way."

## Read the trace first

```crystal
runtime.trace.lines.each { |line| puts line }
```

The trace is the event log rendered with one event per line, tags in
brackets, short summaries. Read it top-to-bottom for a small run, scan
for tag patterns in a large one. Every event the framework emits has a
tag and a payload summary; nothing happens that isn't in the trace.

For a saved run at the shell:

```bash
chronicle-cli log inspect -f run.log
```

Output is unbounded in this port; pipe it through `tail` when you only
want the end of the log.

## Narrow with the event log

The three diagnostic questions that come up repeatedly map to small
library queries:

```crystal
# One event's full payload (every error message names an event id;
# this is the next click):
event = runtime.store.get_event("evt_005")
puts event.try(&.payload)

# Behaviors registered in this run (compare against what fired in the
# trace to spot missing dispatch):
status = runtime.status
status.registered_behaviors.each { |b| puts "#{b.name} #{b.subscribed_to}" }

# Pack versions and prompt content hashes (compare against
# replay-divergence errors to spot prompt drift):
runtime.store.iter_events
  .select { |e| e.type == "pack.loaded" }
  .each { |e| puts e.payload }
```

`runtime.trace.events` is the run's events as objects, in log order —
the usual way to pick an event id for `runtime.fork(at_event: ...)` or
to filter by type without parsing trace lines.

## Read `behavior.failed` events

Most failures inside a goal run land as `behavior.failed` events, not as
escaped exceptions. The runtime catches the behavior's exception,
captures the type/message/reason, emits the event, and keeps going. The
trace shows them inline:

```text
[behavior.failed]   evt_NNN  your.behavior  reason=llm.parse_error
```

To read the full payload (the original exception, the provider/tool
response, any extras):

```crystal
failure = runtime.store.get_event("evt_NNN")
puts failure.try(&.payload)
```

The structured `reason` codes group failures by recovery shape. The
runtime also stamps each `behavior.failed` payload with a `doc_url`
pointing at the reference page for the reason.

### Get the full traceback

Every `behavior.failed` payload carries the complete traceback of the
exception that failed the behavior. `runtime.trace.failures` returns
those events directly, and `runtime.errors` returns them as structured
`BehaviorFailure` values:

```crystal
runtime.trace.failures.each do |failure|
  payload = JSON.parse(failure.payload).as_h
  puts "#{payload["behavior"]} failed on #{payload["event_id"]}:"
  puts payload["traceback"]?.try(&.as_s?)
end

# Or the structured projection:
runtime.errors.each do |error|
  puts "#{error.behavior} #{error.reason} #{error.exception_type}: #{error.message}"
end
```

This is the fastest loop while developing a pack: run the goal, print
`runtime.trace.failures`, fix, rerun. The one-line trace entry stays
terse by design — the traceback lives in the payload, not the trace
format.

## Walk the causal chain

Every event carries `caused_by` — the id of the event that triggered
the behavior that produced this one. Walking the chain backward
reconstructs the causal path from any event to its root.

```crystal
# Walk backward from a specific event:
event = runtime.store.get_event(event_id)
chain = [] of Chronicle::Event
while event
  chain << event
  parent_id = event.caused_by
  event = parent_id ? runtime.store.get_event(parent_id) : nil
end

chain.reverse_each do |e|
  puts "#{e.id}  #{e.type}  #{e.actor}"
end
```

There is also a one-call renderer that walks `caused_by` links from an
**object** back to the goal that created it:

```crystal
graph = runtime.graph.not_nil!
puts Chronicle::Trace.causal_chain(runtime.store.iter_events, graph, "claim#1")
```

The chain ends at a root event — usually `goal.created` (an
operator-pushed goal) or a custom event from outside the runtime loop.
Reading the chain is the answer to "why did this fire?"

## Fork-and-replay-in-isolation for narrowing bugs

When the question is "is the bug in this specific behavior, or
upstream?", fork the run at a point before the suspected behavior fires,
re-run with the behavior modified or removed, and diff:

```crystal
# Fork from the event just before the suspect behavior fired:
fork = runtime.fork(
  at_event: evt_before,
  label: "suspect-removed",
  replay_llm_cache: true,
  replay_tool_cache: true,
)

# Run the fork through your modified behavior set, then diff:
fork.run_until_idle
diff = runtime.diff(fork)
diff.divergent_objects.each { |obj| puts obj.summary }
```

The diff output shows shared events, parent-only events, fork-only
events, and divergent objects. The first divergent object tells you
where the new behavior set started producing different work.

The CLI can fork an encoded log at a sequence point for offline
inspection:

```bash
chronicle-cli fork -f run.log -a 42 -o suspect-removed.log
chronicle-cli diff -a run.log -b suspect-removed.log
```

## When the bug is in your prompt

LLM behaviors are debug-instrumented by default. Every call lands two
events:

```text
[llm.requested]    evt_NNN  your.behavior  model=... prompt_hash=...
[llm.responded]    evt_NNN  your.behavior  cache_hit=false ...
```

To read the full prompt the framework assembled:

```crystal
request = runtime.store.get_event("llm_requested_evt_id")
puts request.try(&.payload)
```

The payload includes the system message, the messages list, and the tool
definitions — exactly what went to the provider. If the behavior's body
parses the response wrong, the `llm.responded` event has the raw
response. If the prompt itself is wrong, the `llm.requested` event is
the source.

For prompt-hash drift across runs (the "this worked yesterday" case),
compare the `pack.loaded` payloads between the two runs. The prompt
content hash is in the `prompts` map; if the hashes differ, the prompt
template changed.

## Reproducing intermittent failures

If a failure only happens sometimes (rate limits, race conditions in
external systems, model temperature variance), the trace from the
failing run is still the most reliable artifact. Save it:

```crystal
File.write("failure.json", runtime.export_trace)
# or, one canonical event per line:
File.open("failure.jsonl", "w") do |io|
  runtime.store.iter_events.each { |event| io.puts event.canonical_json }
end
```

Then re-run against the recorded fixtures — `replay_llm_cache: true` and
`replay_tool_cache: true` reconstruct the runtime's LLM/tool caches from
the recorded events (`LLMCache.from_events` / `ToolCache.from_events`)
and serve recorded responses by request hash deterministically, so the
failing path runs the same way every time. A missing fixture raises an
`llm.fixture_missing`-family failure, which is informative on its own.

> **Divergence:** upstream ships a `RecordedLLMProvider` class. The
> Crystal port expresses recorded replay through the runtime's LLM/tool
> caches rather than a provider class; direct Anthropic/OpenAI clients
> are out of scope (the Crig `ModelExecutor` seam owns provider wiring).
> See `plans/parity.md`.

## What's related

- The trace — the rendered form of the event log.
- `runtime.errors` / `BehaviorFailure` — why most failures are events,
  not exceptions.
- [Fork, test, promote](../guides/fork-test-promote.md) — the primitive
  for fork-and-replay-in-isolation debugging.
- [Operating in production](../guides/operating-in-production.md) —
  the production-facing operator guide; this page is the
  developer-facing complement.
