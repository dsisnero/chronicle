# Pack Authoring Guide

A **pack** is a Crystal module that bundles object types, relation
types, behaviors, tools, prompts, and policies for a specific domain.
Packs are how a developer goes from "I installed chronicle" to "I have
a working diligence system in ten minutes."

This document is the canonical reference for the pack format. It is
companion reading to `src/chronicle/packs/diligence.cr` (the reference
pack / executable spec) and `examples/diligence_real_run.cr` (the
killer demo). Where generation-specific notes disagree, the code and
specs under `src/chronicle/packs/` win.

---

## TL;DR

```crystal
# my_pack/my_pack.cr
require "chronicle"
require "./my_pack/settings"
require "./my_pack/object_types"
require "./my_pack/behaviors"

module MyPack
  include Chronicle::Packs::DSL

  pack(
    name: "my_pack",
    version: "0.1.0",
    description: "Extracts insights from documents.",
    settings_schema: MyPackSettings,
    prompts: Chronicle::Packs.load_prompts_from_dir(File.join(__DIR__, "prompts")),
  )
end
```

```crystal
# user code
runtime.load_pack(MyPack::PACK, settings: {"threshold" => JSON::Any.new(0.8)})
runtime.run_goal("...")
```

That's the whole contract. The rest of this guide explains why each
piece is shaped the way it is, and the conventions third-party pack
authors are expected to follow.

---

## 1. A pack is a Crystal module, not a manifest

There is no required `manifest.toml` for a pack to load. There is a
Crystal file that declares a module and exports a single `PACK`
constant of type `Chronicle::Packs::Pack` via the `pack(...)` macro.

Why: packs need to express real logic (behaviors, prompts, policies)
and Crystal is the right language for that. A declarative manifest
would shove logic into prose comments or template strings. (An optional
`manifest.toml` exists as an *integrity/warning tier* — see
[§13](#13-the-packloaded-event) and
[§14](#14-pack-scaffolding) — but it is never the source of truth.)

Convention: a pack shard has the layout

```text
my_pack/
  shard.yml
  my_pack.cr              # module + pack(...)
  my_pack/
    version.cr            # MyPack::VERSION
    settings.cr           # the JSON::Serializable settings struct
    object_types.cr       # @[ObjectType] structs + @[RelationType] structs
    behaviors.cr          # @[Behavior] / @[LLMBehavior] / @[RelationBehavior]
    tools.cr              # @[Tool]
    prompts/
      <prompt_name>.md    # one per LLM behavior, with TOML frontmatter
  spec/
    my_pack_spec.cr       # smoke test
  README.md
```

The scaffolding command (`Chronicle::Packs::Scaffold.scaffold_pack`)
generates this layout.

---

## 2. Pack-aware annotations: the DSL collects them

Pack code uses **pack-aware annotations** brought into scope by
`include Chronicle::Packs::DSL`:

```crystal
module MyPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "extract_claims", on: ["document.created"])]
  def extract_claims(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # ...
  end

  @[LLMBehavior(name: "summarize", on: ["document.created"])]
  def summarize(event, graph, ctx, output : String)
    # ...
  end

  @[RelationBehavior(name: "unblock", relation_type: "depends_on", on: ["task.completed"])]
  def unblock(relation : Chronicle::GraphRelation, event, graph, ctx)
    # ...
  end

  @[Tool(name: "fetch_docs", description: "Fetch company docs.")]
  def fetch_docs(args : String) : String
    # ...
  end

  pack(name: "my_pack", version: "0.1.0")
end
```

The `pack(...)` macro collects the annotated methods and constants at
compile time and builds the `PACK` constant. The annotations have the
same *shape* as upstream's decorators but they are resolved
statically, not by runtime signature introspection (no dynamic
`**kwargs` injection).

Why: a pack module must be safe to require without a runtime. Requiring
the diligence pack must not put `claim_extractor` into any global
behavior registry, where it would silently fire in a `Runtime` call
regardless of whether the pack was loaded. In Chronicle the only global
registration is the **discovery registry** (so `Packs.load_by_name`
can find the pack); pass `register: false` to `pack(...)` to opt out.

Pack specs can construct a pack, assert its shape, and verify it loads
cleanly without ever instantiating a runtime.

---

## 3. The `Pack` type

```crystal
struct Chronicle::Packs::Pack
  getter name : String
  getter version : String
  getter description : String
  getter object_types : Array(ObjectType)
  getter relation_types : Array(RelationType)
  getter behaviors : Array(PackBehavior)
  getter tools : Array(Tool)
  getter policies : Array(PackPolicy)
  getter prompts : Array(PackPrompt)
  getter settings_schema : String            # e.g. "MyPackSettings"
  getter settings_builder : Proc(JSON::Any?, Hash(String, JSON::Any))
  getter capabilities : Array(CapabilityDecl)
end
```

**Immutable by convention.** A `Pack` is a value; it is not mutated
after construction.

**Identity by `(name, version)`.** Equality and hashing are based on
the pair, not field-by-field comparison. That key is what idempotent
loading and replay hinge on.

**Arrays, not tuples.** Crystal's type system treats a `Pack` as a
value; the compiler enforces the shapes.

`Pack.new` validates:

- `name` is a non-empty lowercase identifier (matches
  `^[a-z][a-z0-9_]*$`)
- `version` is non-empty
- object types have unique names within the pack
- relation types have unique names within the pack
- behavior names are unique within the pack
- tool names are unique within the pack
- policy names are unique within the pack
- prompts have unique names within the pack
- capabilities are unique by `provider.capability`, with a known
  `risk_class` (`low|medium|high|critical`) and optional
  `action_class` (`R0`–`R4`)

Validation failures raise `PackValidationError` at construction — not
at load. The `pack(...)` macro additionally checks at compile time
that `settings_schema` is a type and that a behavior declaring a
`settings` parameter belongs to a pack that declares a schema.

---

## 4. Object types and relation types

A pack declares its object types as `JSON::Serializable` structs
annotated with `@[ObjectType]`:

```crystal
module MyPack
  include Chronicle::Packs::DSL

  @[ObjectType(name: "claim", description: "A factual statement with confidence.")]
  struct Claim
    include JSON::Serializable

    property text : String
    property confidence : Float64
    property source_url : String? = nil
  end

  @[RelationType(name: "addresses", source_types: ["claim"], target_types: ["question"])]
  struct AddressesRel; end

  @[RelationType(name: "supports", source_types: ["evidence"], target_types: ["claim"])]
  struct SupportsRel; end
end
```

When the pack is loaded, `graph.add_object("claim", data)` validates
`data` against `Claim`. Validation errors raise `PackSchemaViolation`
(subclass of `ValueError` / `DomainError`) and no object is created.
The exception names the object type, the pack that declared it, and the
underlying parse error.

> **Divergence (see `plans/parity.md` "Intentional Divergence"):**
> Pydantic `Field(ge=...)`-style constraint annotations are not
> supported. Crystal validates type shape and requiredness through
> `JSON::Serializable`; range/format constraints must be enforced in
> behavior code.

**Load-order asymmetry** (v0.9 #5): validation applies only to objects
created **after** the pack loads. Objects created before the
`pack.loaded` event are not retroactively validated. The `pack.loaded`
event is part of the event log, so replay enforces the same load order.

Object types and relation types declared by a pack are **global to the
runtime**, not pack-scoped. Two packs declaring object type `claim`
with different schemas raise `PackConflictError` at load time — you
cannot have two definitions of `claim` in one runtime.

---

## 5. Behaviors are namespace-prefixed

A behavior declared in a pack with `name: "claim_extractor"` is
registered as `diligence.claim_extractor`. The fully-qualified form
is the **canonical** identifier:

- the trace prints `[behavior.started] diligence.claim_extractor`
- metrics labels read `{behavior="diligence.claim_extractor"}`
- error messages name the prefixed form
- `runtime.status.registered_behaviors` lists prefixed names
- the replay manifest uses prefixed names

Lookups from user code are **lenient**. A short name resolves when
unambiguous; the load-time conflict check makes "unambiguous" a
load-time invariant:

```crystal
runtime.get_behavior("claim_extractor")           # works when unambiguous
runtime.get_behavior("diligence.claim_extractor") # always works
```

Same rule for tools (`diligence.fetch_company_docs`). LLM behaviors
with `tools: ["fetch_company_docs"]` resolve the short name through
the same rule — short forms work when only one pack declares the
tool.

Why this asymmetry: the canonical form is what shows up in
operational artifacts where ambiguity is dangerous (a trace, a
metric query, an error log). User code, on the other hand, is checked
at load time, so leniency is safe.

---

## 6. Tools are pack-scoped by default

```crystal
@[Tool(name: "fetch_company_docs", description: "Fetch documents for a company.")]
def fetch_company_docs(args : String) : String
  # ...
end
```

This tool is registered as `diligence.fetch_company_docs`. To opt
into the global tool namespace:

```crystal
@[Tool(name: "public_helper", description: "Shared helper.", export_globally: true)]
def public_helper(args : String) : String
  # ...
end
```

`export_globally: true` registers the tool under its short name
**also**. The pack-prefixed name is always available. This is intended
for infrastructure packs that explicitly provide tools for other packs
to use. The default is scoped so that pack tools cannot silently
collide with each other or with user-defined tools.

A tool body may declare `args` plus an optional `ctx`:

```crystal
@[Tool(name: "probe", description: "Inspect the triggering context.")]
def probe(args : String, ctx : Chronicle::ToolContext) : String
  # ctx.behavior_name / ctx.event_id / ctx.frame_id / ctx.idempotency_key /
  # ctx.external_io_mode
  "{}"
end
```

The DSL raises at compile time if a `@[Tool]` method declares any
parameter other than `args` / `ctx`.

---

## 7. Settings: typed injection is primary

Every pack may declare a `settings_schema` — a `JSON::Serializable`
struct that includes `Chronicle::Packs::SettingsSchema`:

```crystal
struct MyPackSettings
  include JSON::Serializable
  include Chronicle::Packs::SettingsSchema

  property threshold : Float64 = 0.5
  property confidence_threshold_for_review : Float64 = 0.7
end
```

If a pack has no configurable settings, omit `settings_schema:` (the
loader uses `EmptySettings`).

The user provides settings at load time as canonical JSON:

```crystal
runtime.load_pack(
  MyPack::PACK,
  settings: {
    "threshold"                      => JSON::Any.new(0.8),
    "confidence_threshold_for_review" => JSON::Any.new(0.7),
  },
)
```

If every field of `settings_schema` has a default, `settings:` may be
omitted. Otherwise omitting it raises `PackSettingsMissingError`.

Behaviors access settings in **one of three forms**, in order of
preference:

### Form 1: typed parameter injection (primary)

The `pack(...)` macro inspects the handler's def at compile time. A
final parameter annotated with the pack's settings type is injected
from the canonical settings hash:

```crystal
@[LLMBehavior(name: "claim_extractor", on: ["object.created"], output_schema: ResearchFindings)]
def claim_extractor(
  event : Chronicle::Event,
  graph : Chronicle::GraphProjection,
  ctx : Chronicle::Packs::BehaviorContext,
  output : ResearchFindings,
  settings : MyPackSettings,
)
  return if output.confidence < settings.confidence_threshold_for_review
  # ...
end
```

Type-checker-friendly. IDE-friendly. Refactor-safe. **Recommended for
all new in-pack behaviors.**

The parameter position depends on the behavior kind:

| Annotation | Handler signature |
|---|---|
| `@[Behavior]` | `(event, graph, ctx[, settings])` |
| `@[LLMBehavior(output_schema: S)]` | `(event, graph, ctx, output : S[, settings])` |
| `@[LLMBehavior]` (untyped) | `(event, graph, ctx, output : String[, settings])` |
| `@[RelationBehavior]` | `(relation, event, graph, ctx[, settings])` |

### Form 2: `ctx.settings` (secondary)

`ctx.settings` returns the canonical settings `Hash(String, JSON::Any)`
for the pack that owns the currently-executing behavior:

```crystal
def claim_extractor(event, graph, ctx, output)
  threshold = ctx.settings["confidence_threshold_for_review"].as_f
  return if output.confidence < threshold
  # ...
end
```

Equivalent to Form 1 at runtime. Use when the type is obvious from
the file context, or when you don't want compile-time injection.

### Form 3: `ctx.pack_settings("other_pack")` (cross-pack, rare)

```crystal
def my_behavior(event, graph, ctx)
  memory_settings = ctx.pack_settings("memory")
  return if memory_settings.nil?   # memory pack not loaded
  # memory_settings is a Hash(String, JSON::Any)
end
```

String-keyed. Returns `nil` for unloaded packs. **Using
`ctx.pack_settings("diligence")` from inside the diligence pack is a
code smell** — use Form 1 or Form 2. This form exists for the rare
case where a behavior needs to read another pack's settings.

> **Divergence:** cross-pack settings return the canonical settings
> hash, not a typed object (typed cross-pack access isn't expressible
> in Crystal). Behavior-local settings stay fully typed.

---

## 8. Prompts: TOML frontmatter, content-hash replay

Pack prompts live in `prompts/` inside the pack shard. Each prompt is
a markdown file with TOML frontmatter between `---` delimiters:

```markdown
---
version = "1.0.0"
name = "claim_extractor"   # optional; defaults to filename without .md
---
You extract factual claims from a document.

For each claim, return:
- text (verbatim, ≤ 200 chars)
- confidence (0.0–1.0, calibrated)
- supporting evidence (verbatim quote)

Do not invent claims. If the document does not support a claim, do not return it.
```

Parsed with the Crystal `toml` shard. The frontmatter MUST include
`version`; other keys are advisory.

Load prompts with the helper:

```crystal
pack = Pack.new(
  # ...,
  prompts: Chronicle::Packs.load_prompts_from_dir(File.join(__DIR__, "prompts")),
)
```

`load_prompts_from_dir`:

- scans `*.md` files in the directory
- parses TOML frontmatter (raises `PackPromptLoadError` on malformed)
- computes a SHA-256 hash of the body, truncated to 16 hex chars
  (`"sha256:abcd...ef01"`)
- returns an `Array(PackPrompt)`, sorted by name

### The hash, not the version, is the replay contract

When the pack loads, the runtime emits a `pack.loaded` event whose
payload includes a `prompts` map: `{prompt_name: {"version": "1.0.0",
"hash": "sha256:..."}, ...}`.

On replay, the same event must be emitted with the same hashes. If
you edit a prompt and don't bump the version, replay fires
`ReplayDivergenceError` — the hash caught it. Bumping the declared
version is good operator practice (it shows up in the trace and in
`pack.loaded` payloads), but it is not the source of truth for
correctness. The hash is. This is by design: humans forget; hashes
don't.

### Referencing prompts from behaviors

Each `@[LLMBehavior]` resolves its prompt by name. If the behavior is
declared in a pack and the pack has a prompt with the same `name=`,
that prompt body is folded into the behavior's description and carried
into the assembled system prompt:

```crystal
# prompts/claim_extractor.md   ← frontmatter version=1.0.0
@[LLMBehavior(name: "claim_extractor", on: ["object.created"])]
def claim_extractor(event, graph, ctx, output)
  # ...
end
```

If you need an explicit override, pass `prompt_template: "..."` to
`@[LLMBehavior]` directly. The template supports `{system}`, `{view}`,
`{event}`, and `{instruction}` placeholders. Inline templates are also
content-hashed and pinned in `pack.loaded`.

---

## 9. Policies

```crystal
policies = [
  Chronicle::Packs::PackPolicy.new(name: "memo_approval", requires_approval: ["memo"]),
  Chronicle::Packs::PackPolicy.new(name: "risk_approval", requires_approval: ["risk"]),
]
```

Loaded policies modify how `graph.add_object` behaves: objects of the
listed types are deferred, and the proposal lands as
`approval.proposed` until `runtime.approve_pack(id)` materializes it.
The pack's auto-approve setting can flip the gating off for a demo.

Policy names are pack-scoped via the same prefixing rule:
`diligence.memo_approval`.

A behavior defers an object behind a policy with `ctx.propose_object`:

```crystal
ctx.propose_object("memo", memo_json, reason: "diligence run complete")
```

The operator-side materialization:

```crystal
runtime.pack_pending_approvals.each do |pa|
  puts "#{pa.id} #{pa.object_type} #{pa.reason}"
  runtime.approve_pack(pa.id, approved_by: "reviewer")
end
```

`Diligence::Settings#auto_approve_memos` (default `true` so the demo
flows without manual intervention) lets the pack flip the gating off.
Set it to `false` to see the approval flow. See
`examples/diligence_real_run.cr` for a runnable demo.

---

## 10. Discovery

Packs register themselves with `Chronicle::Packs::Registry` when their
module is required (the DSL's `pack(...)` with the default
`register: true`). Crystal has no Python-style entry-point scan; this
explicit registry is the analogue.

```crystal
require "my_pack"

Chronicle::Packs.discover.each do |entry|
  puts "#{entry.name} #{entry.version}"
end

runtime.load_pack(Chronicle::Packs.load_by_name("my_pack"))
```

`discover` is cached per process; call
`Chronicle::Packs.clear_discovery_cache` to force a re-scan (useful in
tests that register packs dynamically). `load_by_name` raises
`PackNotFoundError` naming the installed packs when the name doesn't
resolve.

---

## 11. Fixtures and reproducible demos

A pack that ships a demo should ship recorded fixtures alongside, so
the demo runs without API keys and produces byte-for-byte identical
output.

The convention in Chronicle:

- Fixtures live inside the pack shard, not in the framework and not
  in the user's `spec/` tree.
- Deterministic runs use a scripted Crig completion model (see
  `examples/support/example_support.cr`) or the runtime's recorded
  LLM/tool caches.
- The `llm_cache` / `tool_cache` are reconstructed from recorded
  events via `LLMCache.from_events` / `ToolCache.from_events` and
  served by request hash during `fork`/`load` — no provider calls.
- Fixture builders are pure Crystal — no I/O at require time, no
  network, no sleeping.
- The demo runs in under 30 seconds in CI.

The shipped Diligence pack and `examples/diligence_real_run.cr` are the
reference layout. The direct Anthropic/OpenAI provider clients are out
of scope in this port (the Crig `ModelExecutor` seam owns provider
wiring); recorded replay is expressed through the LLM/tool caches
rather than a `RecordedLLMProvider` class. See `plans/parity.md`.

---

## 12. Pack discovery and loading: idempotency

`runtime.load_pack(pack, settings: ...)` is **idempotent on `(name,
version)`**. Calling it twice with the same `(name, version)` is a
no-op (no second `pack.loaded` event, no re-prefixing).

Loading the same `name` with a different `version` raises
`PackVersionConflictError` — install conflicts. The runtime cannot
hold two versions of the same pack.

Loading two distinct packs that conflict on object types, relation
types, behavior names, tool names, or policy names raises
`PackConflictError`. The error names both packs and the conflicting
identifier. **Conflict detection runs before any state mutation** —
a failed `load_pack` leaves the runtime unchanged.

### Disabling a pack (v1.4)

`runtime.disable_pack(name)` deregisters a loaded pack **now**: its
behaviors stop matching, its tools stop resolving, its typed schemas
stop enforcing (the types revert to untyped semantics), and a
queue-visible `pack.disabled` event records the deregistered surface
for audit and boot-time loaders. What it deliberately does not do:
touch pack-created state (history is never rewritten) or reclaim
memory (restart to evict). Idempotent — a second disable returns
`false`; a never-loaded name raises `PackNotFoundError`. Re-enable by
calling `load_pack` again.

---

## 13. The `pack.loaded` event

```json
{
  "id": "evt_005",
  "type": "pack.loaded",
  "payload": {
    "name": "diligence",
    "version": "0.1.0",
    "description": "Investment diligence ...",
    "object_types": ["company", "document", "question", "claim", "..."],
    "relation_types": ["supports", "contradicts", "..."],
    "behaviors": ["diligence.question_generator", "diligence.researcher", "..."],
    "tools": ["diligence.fetch_company_docs", "..."],
    "policies": ["diligence.memo_approval", "diligence.risk_approval"],
    "prompts": {
      "question_generator": {"version": "1.0.0", "hash": "sha256:..."}
    },
    "settings": {"<canonical JSON settings>": "..."},
    "capabilities": []
  }
}
```

`pack.loaded` lives in the event log. The trace renders it; the JSONL
export includes it; the CLI surfaces it. It is NOT suppressed from the
queue — pack-aware behaviors can subscribe to `pack.loaded` to
bootstrap.

Re-loading an already-loaded pack does not emit a second
`pack.loaded`. The settings payload is canonical-JSON-serialized so
diffs between runs surface settings drift.

---

## 14. Pack scaffolding

```crystal
Chronicle::Packs::Scaffold.scaffold_pack(target_dir: ".", raw_name: "my-pack")
```

The scaffolding call produces a shard that:

- declares `chronicle` as a dependency
- exports a `PACK` constant via the annotations DSL
- has stubs for object types, behaviors, tools, settings
- has a `spec/<module>_spec.cr` smoke test that asserts the manifest
  is discoverable

The package name (directory and Crystal module) is the kebab-to-snake
transformation of the pack name: `"diligence-extension"` produces
`diligence-extension/` with internal module
`DiligenceExtension`.

> **Divergence:** upstream ships `activegraph pack new` / `pack list`
> CLI subcommands. The Crystal `chronicle-cli` does not expose a `pack`
> subcommand; scaffolding and discovery are library calls
> (`Scaffold.scaffold_pack`, `Packs.discover`). See `plans/parity.md`.

---

## 15. Trust model and packs as code

**Packs are not sandboxed.** A pack is a Crystal shard. Installing a
pack is equivalent to installing any Crystal dependency: it can read
your files, make network calls, and link arbitrary code into your
process. Trust at install time, not at runtime.

The runtime does not enforce any pack-specific privilege restrictions
on the live path. `Chronicle::Sandbox` (forked-trial execution) exists
for testing candidate packs in isolation, but it is a separate seam,
not a pack-loading restriction. If you don't trust a pack's source,
don't install it.

---

## 16. Backward compatibility

The pack format is additive. Global runtime behavior with no packs
loaded is unchanged. Behaviors, tools, and object types that predate
the pack format continue to work when expressed through the DSL.

The Crystal port deliberately diverges from upstream's Python
decorators and Pydantic models; see `plans/parity.md` "Intentional
Divergence" for the full ledger.

---

## 17. Where to look in the reference implementation

- `src/chronicle/packs/value_objects.cr` — `Pack`, `ObjectType`,
  `RelationType`, `PackPolicy`, `CapabilityDecl`.
- `src/chronicle/packs/annotations.cr` — the DSL, the annotations,
  and the `pack(...)` macro.
- `src/chronicle/packs/behavior.cr` — `PackBehavior` + `BehaviorContext`.
- `src/chronicle/packs/loader.cr` — `Runtime#load_pack` internals,
  conflict detection, namespace prefixing, settings injection.
- `src/chronicle/packs/discovery.cr` — registry enumeration.
- `src/chronicle/packs/scaffold.cr` — `scaffold_pack`.
- `src/chronicle/packs/manifest.cr` — the optional `manifest.toml`
  integrity/warning tier.
- `src/chronicle/packs/diligence.cr` — the reference pack. Read this
  end-to-end before writing your own.
- `examples/diligence_real_run.cr` — the killer demo / executable
  spec for the pack format.
- `spec/chronicle/packs_*_spec.cr` — every property in this document
  is tested.
