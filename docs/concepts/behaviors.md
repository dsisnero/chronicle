# Behaviors

A behavior is the framework's unit of reactive code. It subscribes to
events, runs when its subscription matches, and produces more events
(new objects, new relations, patches, custom events). The runtime
dispatches behaviors against events in the queue until the queue is
empty.

Behaviors are how a developer adds custom logic to the framework. Most
code that ships with a pack is behaviors. Most code a developer writes
is behaviors.

A behavior is **not an agent.** It doesn't decide what to do — it
reacts. The decision is the subscription rule; the work is the body. An
agentic-feeling system emerges from many small behaviors firing in
response to each other's outputs, not from one agent-orchestrator
behavior calling everything else.

## The annotation

Behaviors live in packs. A pack is a Crystal module that
`include Chronicle::Packs::DSL`; annotated methods are collected at
compile time by the `pack(...)` macro.

```crystal
module ContradictionDetector
  include Chronicle::Packs::DSL

  @[Behavior(
    name: "contradiction_detector",
    on: ["object.created"],
    where: {"type" => "claim"},
    pattern: "(c:claim)-[:contradicts]->(other:claim)",
    activate_after: 1
  )]
  def contradiction_detector(event : Chronicle::Event,
                             graph : Chronicle::GraphProjection,
                             ctx : Chronicle::Packs::BehaviorContext)
    ctx.matches.each do |match|
      # match["c"], match["other"] are object ids
    end
  end

  pack(name: "contradiction_detector", version: "0.1.0")
end
```

**Divergence:** upstream uses Python decorators (`@behavior`, ...).
Chronicle uses Crystal annotations (`@[Behavior(...)]`, ...) collected
by the `pack(...)` macro. Nothing registers globally; the `Pack`
constructor is the only thing that sees these declarations, and the
pack is activated with `runtime.load_pack(ContradictionDetector::PACK)`.

Every argument is a separate activation condition; the behavior fires
when **all** of them hold:

- `on:` — event types the behavior subscribes to. Most behaviors
  subscribe to a single type (`object.created`, `goal.created`, custom
  event names).
- `where:` — a hash-shaped filter on the event payload. Equality on
  values; nested keys via dotted paths.
- `pattern:` — a Cypher-subset pattern subscription. The behavior fires
  only when the pattern matches the graph at event time. See
  [`patterns`](patterns.md) for the locked subset and grammar.
- `creates:` — an optional list of object types the behavior is expected
  to create, used for routing/dispatch metadata.
- `activate_after:` — schedule the behavior to fire N events after the
  triggering event. Integer event count only; wall-clock units are
  refused (raises `InvalidActivateAfter`).

## The signature

```crystal
def my_behavior(event : Chronicle::Event,
                graph : Chronicle::GraphProjection,
                ctx : Chronicle::Packs::BehaviorContext)
end
```

- `event` — the triggering `Chronicle::Event`, with `id`, `type`,
  `payload`, `actor`, `caused_by`, `frame_id`, `timestamp`. `payload` is
  a canonical JSON string; parse it with `JSON.parse(event.payload)`.
- `graph` — the `GraphProjection` as it existed at event time.
- `ctx` — the runtime-bound context, with `.matches` (pattern
  bindings), `.view` (the scoped view), `.settings`, `.pack_settings`,
  `.propose_object` (the approval-gated add path), and `.embed`.

The body mutates the graph by calling `graph.add_object`,
`graph.patch_object`, `graph.add_relation`, `graph.remove_object`, or
emits arbitrary events via `graph.emit(type, payload)`. Each mutation
lands as an event in the log; downstream behaviors react.

A behavior may also take a trailing `settings` parameter. When the pack
declares a `settings_schema`, the handler is injected with the canonical
settings for the pack:

```crystal
@[Behavior(name: "reviewer", on: ["object.created"],
  where: {"type" => "claim"})]
def reviewer(event : Chronicle::Event,
             graph : Chronicle::GraphProjection,
             ctx : Chronicle::Packs::BehaviorContext,
             settings : MyPack::Settings)
  threshold = settings.confidence_threshold_for_review
  # ...
end
```

The arity is validated at compile time by the `pack` macro: a behavior
without the three core parameters will not compile.

## The three behavior kinds

- **Regular `@[Behavior]`** — the workhorse. Reacts to events, mutates
  the graph. Synchronous, deterministic.
- **`@[LLMBehavior]`** — wraps a method whose return value comes from an
  LLM call. The framework handles the prompt assembly, the provider
  call, the cache, the tool loop, and the schema validation; the body
  receives the parsed LLM output and turns it into graph mutations. When
  `output_schema:` names a `JSON::Serializable` struct, the handler's
  final parameter is that typed value.
- **`@[RelationBehavior]`** — attached to a relation type rather than an
  event type. Fires when an event affects an endpoint of the relation.
  See [`relations`](relations.md).

LLM behaviors are configured through the annotation:

```crystal
struct Extracted
  include JSON::Serializable
  property claims : Array(String)
end

@[LLMBehavior(name: "extractor", on: ["object.created"],
  where: {"type" => "document"},
  output_schema: Extracted,
  model: "claude-sonnet-4-5",
  tools: ["summarize_document"],
  view: {around: "event.payload.id", depth: 1},
  description: "Extract claims from the document.")]
def extractor(event : Chronicle::Event,
              graph : Chronicle::GraphProjection,
              ctx : Chronicle::Packs::BehaviorContext,
              output : Extracted)
  output.claims.each do |text|
    graph.add_object("claim", %({"text":#{text.to_json},"confidence":0.5}))
  end
end
```

Structured outputs are `JSON::Serializable` structs passed to
`output_schema:`. Providers are reached through the Crig
`ModelExecutor` / `ProviderRegistry` seam; direct Anthropic/OpenAI
client classes are intentionally out of scope (see
[`plans/parity.md`](../../plans/parity.md)).

## The determinism contract

Behavior bodies must be **deterministic given their inputs**. Same
event, same graph state, same view → same mutations. This is the
load-bearing assumption that makes replay and forking work. Two
practical consequences:

- **No `Random`, no `Time.utc`, no `Random::Secure.uuid` in behavior
  bodies.** If you need randomness or wall-clock time, get it from the
  event (which carries the recorded timestamp) or from the runtime's
  deterministic id generator (`graph.ids`).
- **No I/O outside the framework's primitives.** Network calls go
  through `@[Tool]` so the framework can cache and replay them. LLM
  calls go through `@[LLMBehavior]` so the prompt-hash cache works.
  Direct `HTTP::Client.get` in a behavior body breaks replay determinism
  in a way the framework can't recover from.

The framework doesn't enforce determinism with static analysis; the
discipline is on the developer. The cost of breaking it is a fork that
produces a different result from its parent.

## The failure model

When a behavior body raises, the runtime catches the exception and emits
a `behavior.failed` event with the original exception's type, message,
and (for LLM/tool errors) the structured `reason` code. The exception
does NOT escape to your code — the loop continues, other behaviors keep
firing, and the operator sees the failure in the trace.

Code that wants to react to failures subscribes to `behavior.failed`.
The retry-behavior pattern is the canonical idiom:

```crystal
@[Behavior(name: "retry_transient", on: ["behavior.failed"],
  where: {"reason" => "llm.network_error"})]
def retry_transient(event : Chronicle::Event,
                    graph : Chronicle::GraphProjection,
                    ctx : Chronicle::Packs::BehaviorContext)
  # re-emit, escalate, or alert
end
```

See [`failure-model`](failure-model.md) for the events-not-exceptions
principle.

## What's related

- [`graph`](graph.md) — the world state behaviors react to and mutate.
- [`events`](events.md) — the append-only history behaviors subscribe
  to.
- [`relations`](relations.md) — the typed-edge primitive and
  `@[RelationBehavior]`.
- [`patterns`](patterns.md) — the Cypher-subset pattern subscription
  primitive.
- [`views`](views.md) — the scoped reads a behavior observes.
- [`failure-model`](failure-model.md) — what happens when a behavior
  body raises.
