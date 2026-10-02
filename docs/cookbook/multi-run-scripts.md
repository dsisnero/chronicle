# Multi-run scripts

A common pattern when scripting against the framework: run a goal,
inspect the result, run another goal in a fresh `Runtime` against a
fresh `GraphProjection`. Tests do this for isolation; user scripts hit
the same shape when they iterate on a hypothesis ("what would happen
with this seed event vs that one") inside one process.

The wrinkle upstream is that Python's `@behavior` decorators populate a
global registry on module import, so each fresh `Runtime` would find the
registry empty (or stale) unless behaviors were re-registered. **Crystal
does not have that problem.** The pack DSL collects behaviors into a
`Pack` value at compile time; nothing registers globally. Behaviors
become live only when you call `runtime.load_pack(MyPack::PACK)` on a
specific runtime, and that registration is per-runtime state.

So the multi-run pattern is simply: hold the `PACK` constant, and build
a fresh runtime + graph + store per run.

```crystal
require "chronicle"

module MyPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "extract_claims", on: ["document.created"])]
  def extract_claims(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # ...
  end

  @[Behavior(name: "check_contradictions", on: ["claim.created"])]
  def check_contradictions(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # ...
  end

  pack(name: "my_pack", version: "0.1.0")
end

# `PACK` is a value captured once. It never leaks into another runtime.
PACK = MyPack::PACK

def run_one(seed_documents : Array(String), agent : Crig::Agent(MyModel)) : Chronicle::GraphProjection
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  log_agent = Chronicle::LogAgent(MyModel).new(agent, store: store, max_turns: 1)
  runtime = Chronicle::Runtime(MyModel).new(store: store, log_agent: log_agent, graph: graph)

  runtime.load_pack(PACK, settings: {"threshold" => JSON::Any.new(0.5)})

  seed_documents.each do |doc|
    graph.add_object("document", doc)
  end

  runtime.run_until_idle
  graph
end

# Now scripts can iterate on hypotheses without stale-registry surprises:
g1 = run_one([%({"title":"Q3 update","body":"..."})], agent)
g2 = run_one([%({"title":"Q4 update","body":"..."})], agent)
g3 = run_one([%({"title":"Annual report","body":"..."})], agent)
```

The same pattern works for `@[RelationBehavior]` and `@[LLMBehavior]` —
`load_pack` registers every kind of behavior the pack declares, in
deterministic dispatch order.

## Why capture the constant rather than re-requiring the module

Crystal caches required files; `require "my_pack"` a second time is a
no-op and re-runs no macro code. There is no stale-registry bug to work
around because the DSL never wrote to a global behavior registry in the
first place — it only registered the pack with the **discovery**
registry (`Chronicle::Packs::Registry`), which is used by
`Packs.discover` / `Packs.load_by_name`.

Capturing `MyPack::PACK` once and calling `load_pack` per run is the
same shape the framework's own specs use. If a test registers packs
dynamically and needs a clean discovery view, call
`Chronicle::Packs::Registry.clear` (or
`Chronicle::Packs.clear_discovery_cache`); that affects discovery only,
never a live runtime's behaviors.

## When NOT to use this pattern

If you only need one `Runtime` per process — the usual shape for a
long-running agent process, a CLI command, or a single script — you
don't need any of this. Define the pack, call `load_pack` once, and
you're done.

The multi-run pattern is for scripts that iterate. Hypothesis sweeps,
A/B comparisons in one process, batch jobs that want per-input graph
isolation without per-input process startup. If the second run should
branch from the first's state rather than start from scratch, **fork**
instead.

## See also

- [Common patterns — Fork-and-diff](common-patterns.md#fork-and-diff-to-compare-alternative-hypotheses)
  — when the second run should branch from the first's state rather than
  start from scratch, fork instead.
- [Debugging](debugging.md) — when a run misbehaves, the trace is the
  first thing to read.
