# Behaviors

The behavior annotations and base classes. For the conceptual model see
[`plans/parity.md`](../../../plans/parity.md) and
[`src/chronicle/packs/behavior.cr`](../../../src/chronicle/packs/behavior.cr).
For activation rules and the determinism contract see
[`src/chronicle/registry.cr`](../../../src/chronicle/registry.cr).

## Decorators / annotations

ActiveGraph uses Python decorators (`@behavior`, `@llm_behavior`,
`@relation_behavior`). Chronicle uses Crystal annotations collected by
the `Chronicle::Packs::DSL.pack` macro; there are no decorators and
nothing registers globally.

```crystal
require "chronicle"

module MyPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "greeter", on: ["company.created"])]
  def self.greeter(
    event : Chronicle::Event,
    graph : Chronicle::GraphProjection,
    ctx : Chronicle::Packs::BehaviorContext,
  ) : Nil
    graph.add_object("greeting", %({"company":"#{event.id}"}))
  end

  pack(name: "my_pack", version: "1.0.0")
end
```

### `@[Behavior]`

| Annotation key | Type | Meaning |
| --- | --- | --- |
| `name` | `String` | Canonical behavior name (defaults to the method name). |
| `on` | `Array(String)` | Event types that trigger the behavior. |
| `where` | `Hash` | Payload predicate (dotted paths; `{"op" => value}` comparisons). |
| `priority` | `Int32` | Tie-break within registration order. |
| `creates` | `Array(String)` | Declared object types the behavior may create. |
| `pattern` | `String` | Cypher-subset pattern subscription. |
| `activate_after` | `Int32 \| String` | Delayed-queue scheduling (`activate_after`). |
| `description` | `String` | Human description; merged with a same-named prompt. |

The handler signature is
`(event : Event, graph : GraphProjection, ctx : BehaviorContext) : Nil`,
optionally with a trailing `settings` argument when the pack declares a
`settings_schema`.

### `@[LLMBehavior]`

Adds the LLM surface to `@[Behavior]`:

| Annotation key | Type | Default |
| --- | --- | --- |
| `model` | `String` | `"claude-sonnet-4-5"` |
| `prompt_template` | `String?` | `nil` |
| `max_tokens` | `Int32` | `4096` |
| `temperature` | `Float64` | `0.7` |
| `top_p` | `Float64` | `1.0` |
| `deterministic` | `Bool` | `false` |
| `view` | `{around:, depth:}` | `nil` |
| `max_tool_turns` | `Int32` | `6` |
| `tools` | `Array(String)` | `[]` |
| `output_schema` | type | `nil` |

With `output_schema:`, the handler receives the **typed** parsed value
(`Chronicle::StructuredOutput` extracts verbatim JSON, a fenced
```` ```json ```` block, or the first balanced `{..}`/`[..]` span), not
the raw string. Failures raise `LLMBehaviorError` with
`llm.parse_error` or `llm.schema_violation`.

```crystal
struct Claim
  include JSON::Serializable
  getter text : String
  getter confidence : Float64
end

@[LLMBehavior(name: "extractor", on: ["document.created"], output_schema: Claim)]
def self.extractor(event, graph, ctx, output : Claim) : Nil
  graph.add_object("claim", output.to_json)
end
```

### `@[RelationBehavior]`

Requires `relation_type`. The handler receives the matched relation:

```crystal
def self.handler(
  relation : GraphRelation,
  event : Event,
  graph : GraphProjection,
  ctx : BehaviorContext,
) : Nil
```

## Base classes

### `Chronicle::Packs::BehaviorContext`

The execution context handed to pack behavior handlers.

| Member | Signature |
| --- | --- |
| `pack_name` | `String` |
| `settings` | `Hash(String, JSON::Any)` |
| `pack_settings` | `(pack_name : String) -> Hash(String, JSON::Any)?` |
| `view` | `Chronicle::View \| ContextRead::TracedView` |
| `matches` | `-> Array(Chronicle::Match)` |
| `propose_object` | `(object_type : String, data : String, *, reason : String = "") -> String` |
| `embed` | `(texts : Array(String), *, model : String? = nil) -> Array(Array(Float64))` |

`propose_object` and `embed` raise `RuntimeContextRequiredError` when the
context was not constructed inside a runtime.

### `Chronicle::Packs::PackBehavior`

The frozen, canonicalized behavior record the runtime dispatches.
`PackBehaviorKind` is `Behavior | LLM | Relation`; a behavior carries
`name`, `event_types`, `where`, `priority`, `creates`, `pattern`,
`relation_type`, `model`, `prompt_template`, token defaults,
`max_tool_turns`, `tools`, `llm_tools`, `activate_after`,
`output_schema_name`/`output_schema_json`, and the handler closures.
`#canonicalize(pack, settings)` prefixes the name with the pack and
stamps ownership.

> Divergence: upstream `Behavior`/`LLMBehavior`/`RelationBehavior` are
> runtime base classes. Chronicle expresses the same contract as
> compile-time annotations plus the `DSL.pack` macro. See
> [`plans/parity.md`](../../../plans/parity.md).

## Matching

`Chronicle::Registry.new(behaviors).match(event, graph)` returns
`RegistryMatch` triples (behavior, matching relations, pattern matches)
in registration order. A behavior with both `on=` and `pattern=`
requires both; a pattern-only behavior matches every non-lifecycle event.
