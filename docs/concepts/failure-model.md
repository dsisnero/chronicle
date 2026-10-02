# Failure model

The framework distinguishes two kinds of failure, and the distinction
governs how you write behaviors, how you read errors, and how you build
on top of the runtime.

## The principle

> **Exceptions are for caller-facing failures the caller can reasonably
> catch and act on. Non-fatal stops — budget exhaustion, behavior
> failures, tool failures, approval denials — are events in the log.
> The distinction: exceptions interrupt control flow; events extend the
> audit trail. When in doubt, an event.**

Behaviors that fail during a run don't raise out to your code. The
runtime catches the exception, emits a `behavior.failed` event with the
original exception's type, message, and `reason` code in the payload,
and the loop continues. Other behaviors keep firing. The operator sees
the failure in the trace; downstream code that subscribes to
`behavior.failed` can react (alert, retry-with-different-args,
escalate).

The same shape applies to tools: a `ToolError` raised inside a tool body
becomes a `tool.responded` event with `error.reason` set, and the calling
behavior's loop reads the structured failure and decides what to do.

The same shape applies to budget exhaustion: when a `max_*` limit is
hit, the runtime emits `runtime.budget_exhausted` with the dimension in
the payload and stops gracefully. No exception escapes to your code —
you read the event from `runtime.status` or from the trace.

## When exceptions are the right answer

Exceptions are for failures the caller is making **right now, at this
line of code**, and can reasonably catch:

- Constructing a runtime with conflicting arguments
  (`InvalidRuntimeConfiguration`)
- Looking up a behavior or tool that isn't registered
  (`BehaviorNotFoundError`, `MissingToolError` / `UnknownToolError`)
- Passing a malformed store URL (`InvalidStoreURL`)
- Replaying a run whose recorded event stream doesn't match the live
  re-run (`ReplayDivergenceError`)
- Calling `runtime.approve` / `runtime.approve_pack` on an id that
  doesn't exist (`ApprovalError`)
- Parsing a pattern outside the locked Cypher subset
  (`UnsupportedPatternError`)

These all interrupt the call. The caller catches the exception, fixes
the input, and tries again. There's no audit-trail entry to preserve
because the call never produced one.

## The exception hierarchy

Every framework exception inherits from `Chronicle::ActiveGraphError`,
which itself descends from `ArgumentError`. Category bases group the
leaves:

```text
ActiveGraphError < ArgumentError
├── DomainError              invalid inputs rejected by the deterministic core
│   ├── StorageError         persistence problems
│   ├── PatternError         pattern subscription syntax errors
│   ├── PackError            pack-specific runtime problems
│   ├── ApprovalError        approval lifecycle misuse
│   └── ...                  event, projection, routing, tool, and LLM leaves
├── ConfigurationError       construction-time / API-call argument errors
│   └── InvalidRuntimeConfiguration
├── RegistrationError        behavior/tool/pack registration problems
│   ├── MissingProviderError
│   └── MissingToolError
├── ExecutionError           runtime execution problems (escaped to the caller)
│   ├── RuntimeContextRequiredError
│   └── UnknownToolError
├── ReplayError              replay/fork divergence
│   └── ReplayDivergenceError
└── PackError (also under DomainError)
```

Catch `Chronicle::ActiveGraphError` to catch every framework exception.
Catch a category base to catch every leaf in that category. Catch a
specific leaf when the recovery is leaf-specific.

**Divergence:** upstream's hierarchy places seven categories directly
under `ActiveGraphError` and multi-inherits leaves from Python builtins
(`EventNotFoundError` is also a `KeyError`, etc.). Chronicle keeps the
root (`ActiveGraphError < ArgumentError`) and the category names, but
places most domain leaves under `DomainError`. Rescue the root or the
category base for portable code; see
[`plans/parity.md`](../../plans/parity.md).

## The structured event types

`behavior.failed`, `tool.responded` (with error),
`runtime.budget_exhausted` — each carries a `reason` field with a stable
discriminator code so downstream code can branch on the failure mode
without parsing prose:

- LLM reasons: `llm.parse_error`, `llm.schema_violation`,
  `llm.fixture_missing`, `llm.rate_limited`, `llm.network_error`,
  `llm.auth_error`, `llm.request_error`.
- Tool reasons: `tool.timeout`, `tool.network_error`,
  `tool.invalid_input`, `tool.invalid_output`, `tool.execution_error`,
  `tool.fixture_missing`, `tool.unknown_tool`.
- Budget reasons: `budget.exhausted`, `budget.tool_calls_exhausted`,
  `budget.cost_exhausted`, `budget.llm_calls_exhausted`, and
  `budget.<dimension>_exhausted` for other dimensions.
- Generic caught exceptions use `exception.<ErrorClass>`.

`RuntimeReason.doc_url_for_reason(reason)` maps a reason to its
documentation page URL, and that URL is written into the
`behavior.failed` payload's `doc_url` field.

## Observing failures in caller code

The framework gives you surfaces for noticing failures without
subscribing a `@[Behavior]` to `behavior.failed`:

**1. The structured `behavior.failed` event.** The payload carries
`behavior`, `event_id`, `reason`, `exception_type`, `message`,
`traceback`, `doc_url`, and any structured extras. Operators read it
from the trace; `chronicle-cli log inspect --file <log>` prints it.

**2. The `Runtime#errors` property.** After a run, inspect failures
programmatically without parsing event payloads:

```crystal
runtime.run_goal("...")
runtime.errors.each do |err|
  if err.reason == "llm.network_error"
    retry_with_backoff(err.event_id)
  end
end
```

Each `err` is a `Chronicle::BehaviorFailure` with these fields:

| Field | Meaning |
| --- | --- |
| `behavior` | the failing behavior's name |
| `event_id` | the triggering event's id |
| `reason` | the reason code (nil for raw exceptions) |
| `exception_type` | the Crystal exception class name |
| `message` | the exception's `message` |
| `failed_event_id` | the `behavior.failed` event's id |

The property reads from the store on each access — the events are the
source of truth and the property is a structured projection. No caching,
no listeners, no new runtime state.

**Divergence:** upstream ALSO emits one WARNING log line on the
`activegraph.runtime` logger per `behavior.failed`, with
`configure_logging` / `get_logger` helpers. Chronicle ships the
structured formatter (`Chronicle::Logging`) but not the stdlib logging
handler setup or the per-emission WARNING line; the structured fields
land in the event instead. See
[`plans/parity.md`](../../plans/parity.md).

The surfaces are *additive* and don't change the failure model: events
stay the durable record, behaviors that fail still don't raise out of
`run_goal`, and code subscribing to `behavior.failed` keeps working
unchanged.

## Dispatch-Time Routing

Most failures that happen while a behavior is executing become
`behavior.failed`. That includes regular behavior body exceptions, LLM
carrier errors (`LLMBehaviorError`), tool carrier errors (`ToolError` /
`UnknownToolError`), and budget checks that stop a behavior before it can
safely continue.

Two dispatch-adjacent failures intentionally escape as exceptions:

- **`ReplayDivergenceError`** during strict replay. Strict replay is a
  caller-requested verification mode; a mismatch means the recorded run
  and the live code no longer agree. Emitting `behavior.failed` would
  hide the verifier's answer inside the log it is checking, so the
  runtime raises to the caller instead.
- **Pattern contract failures before behavior invocation.** Unsupported
  pattern syntax is rejected at parse/registration time. If a pattern
  evaluator hits an unsupported shape while matching, no behavior body
  has started and no behavior-owned recovery path exists; the runtime
  raises the pattern error rather than inventing a `behavior.failed`
  event for work that never began.

The boundary is: once the runtime has entered a behavior body or an
LLM/tool sub-step owned by that behavior, recoverable failures are
events. Verification and contract-validation failures at runtime entry
points remain exceptions.

## "When in doubt, an event"

If you're writing a behavior and you're about to raise an exception
because something downstream "should never happen," ask:

- Can the caller reasonably catch and act on this?
- Is the failure attributable to a specific event in the log?

If the answer to the first is "no" and the answer to the second is
"yes," emit an event instead. The audit trail is the durable record;
exceptions are just the runtime's way of refusing the current call.

This rule is why there is no `BehaviorFailedError` or
`BudgetExhaustedError` in the exception hierarchy: their information
already lives in events.

## What's related

- [`behaviors`](behaviors.md) — what happens when a behavior body raises.
- [`events`](events.md) — the append-only history and the events-vs-
  exceptions distinction.
- [`patches`](patches.md) — patch rejection as state, patch misuse as an
  exception.
- [`policies`](policies.md) — approval denials as events.
- [`replay`](replay.md) — why divergence is an exception.
