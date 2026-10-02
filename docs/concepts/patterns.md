# Pattern subscriptions

Behaviors fire on event types by default (`@[Behavior(on: ...)]`). For
richer triggers — match an event against the current graph and fire only
when a specific structural pattern holds — behaviors subscribe to a
**pattern** instead.

Pattern subscriptions are a first-class activation primitive, alongside
event-type subscriptions and `where:` filters. A behavior can use any
combination of the three; all conditions must hold for the behavior to
fire.

## Syntax

Patterns are written in a strict subset of Cypher:

```crystal
matcher = Chronicle.parse(
  "(c:claim)-[:supports]->(e:evidence) WHERE c.confidence > 0.7"
).compile

# Apply to (event, graph) — the event may be nil for a pure graph query.
matcher.matches(nil, graph).each do |match|
  claim_id = match["c"]
  evidence_id = match["e"]
end
```

Inside a behavior, the runtime supplies the matches for the current
invocation; iterate `ctx.matches`:

```crystal
@[Behavior(name: "risk_escalator",
  pattern: "(c:claim)-[:supports]->(e:evidence) WHERE c.confidence > 0.7")]
def risk_escalator(event : Chronicle::Event,
                   graph : Chronicle::GraphProjection,
                   ctx : Chronicle::Packs::BehaviorContext)
  ctx.matches.each do |match|
    claim_id = match["c"]
    evidence_id = match["e"]
  end
end
```

`ctx.matches` is an array of `Chronicle::Match` values, one per distinct
binding combination that satisfies the pattern. Iteration is the
developer's responsibility — the framework does not collapse matches
into a single fire-per-event; each match is exposed and the behavior
body decides what to do with them. A `Match` exposes `bindings`
(`Hash(String, String)`), `match["c"]`, and `match.get("c")`.

## What the subset supports

- **Node patterns:** `(var:type {prop: value, ...})`. Properties are
  equality-only; comparisons go in `WHERE`.
- **Relationship patterns:** `(a)-[var:rel_type]->(b)` and
  `(a)<-[var:rel_type]-(b)`. Direction is required.
- **Multi-hop:** `(a)-[:r1]->(b)-[:r2]->(c)`.
- **`WHERE` clauses:** comparisons (`=`, `<>`, `<`, `<=`, `>`, `>=`),
  `AND`, `NOT`, `NOT EXISTS { ... }`.

The full grammar is enforced by the parser in
`src/chronicle/patterns.cr`. Anything outside the subset raises
`UnsupportedPatternError` at parse/registration time, not at match time
— `Chronicle.parse` validates the pattern when it runs.

## What the subset deliberately refuses

The subset is small on purpose. A fuzzy superset of Cypher would let
patterns appear to match input they did not actually match, which would
corrupt the audit trail that pattern-driven behaviors are designed to
preserve. Specifically refused (each with a documented workaround in the
error message that fires):

- **OR in WHERE clauses.** Register two behaviors, one per branch of the
  disjunction.
- **`RETURN`, `WITH`, multiple `MATCH`.** Patterns observe; they don't
  compose pipelines. Express the pipeline as multiple behaviors chained
  through emitted events.
- **Variable-length paths (`-[*]-`).** Unbounded match cost. Express as
  N separate one-hop patterns if the lengths are bounded.
- **`OPTIONAL MATCH`.** No null binding. Register a second behavior
  whose pattern is the optional sub-pattern.
- **Aggregation, `UNWIND`, `UNION`.** Iterate in the behavior body
  instead — `ctx.matches` is the iteration surface.
- **`CREATE`, `MERGE`, `SET`, `DELETE`, `DETACH`.** Patterns observe;
  they don't mutate. Mutations go in the behavior body via
  `graph.add_object`, `graph.patch_object`, `graph.remove_object`.

CONTRACT v0.7 #8 locked the subset and is the canonical reference for
why each refusal stands.

## Composition with event-type and `where:` subscriptions

Pattern subscriptions combine with the other activation conditions:

```crystal
@[Behavior(
  name: "contradiction_detector",
  on: ["object.created"],
  where: {"type" => "claim"},
  pattern: "(c:claim)-[:contradicts]->(other:claim)"
)]
```

This behavior fires when **all three** conditions hold: an
`object.created` event occurred, the new object's type is `claim`, and
the new claim has an outgoing `contradicts` edge to another claim. The
pattern is evaluated against the graph at the time the event fires; the
new object is present in the match if the pattern references it.

## When to use the relationship variable

`(a)-[r:type]->(b)` binds `r` to the relation id so the behavior body can
read the relation. `(a)-[:type]->(b)` binds nothing; the relation is part
of the match but its id isn't available. Use the variable form when the
behavior needs to read the relation; omit it when the relation is just a
structural constraint.

## Tracing pattern fires

Each behavior fire produced by a pattern subscription emits a
`pattern.matched` event ahead of the `behavior.started` event. The trace
shows how many matches the pattern produced for that fire:

```text
[pattern.matched]    evt_042  contradiction_detector  matches=2
[behavior.started]   contradiction_detector
```

The match count is also in the event's payload for downstream code that
wants to subscribe to pattern matches without owning the behavior.

## Related

- [`behaviors`](behaviors.md) — the broader behavior model. Pattern
  subscriptions are one of the activation conditions.
- [`graph`](graph.md) — the world state the matcher reads.
- [`failure-model`](failure-model.md) — the framework's stance on what
  counts as a recoverable failure. The "refuse rather than fuzzy-match"
  choice for the pattern subset is one application of the broader
  principle.
