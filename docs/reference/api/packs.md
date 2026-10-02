# Packs

The pack format primitives. A pack is a bundle of object types,
relation types, behaviors, tools, prompts, and policies for a domain.
For the authoring workflow see
[`src/chronicle/packs/scaffold.cr`](../../../src/chronicle/packs/scaffold.cr)
and [`src/chronicle/packs/diligence.cr`](../../../src/chronicle/packs/diligence.cr)
for the shipped reference pack.

Crystal packs use the `Chronicle::Packs::DSL` macro + annotations rather
than Python decorators. The `pack(...)` macro collects declarations at
compile time and registers the resulting `Pack` unless `register: false`.

```crystal
module MyPack
  include Chronicle::Packs::DSL

  @[ObjectType(name: "item")]
  struct Item
    include JSON::Serializable
    getter name : String
  end

  pack(
    name: "my_pack",
    version: "1.0.0",
    description: "Example pack",
    settings_schema: Chronicle::Packs::EmptySettings,
  )
end
```

## Pack declaration

### `Chronicle::Packs::Pack`

Frozen bundle. Identity/equality is by `(name, version)`.

| Field | Type |
| --- | --- |
| `name` | `String` (`[a-z][a-z0-9_]*`) |
| `version` | `String` |
| `description` | `String` |
| `object_types` | `Array(ObjectType)` |
| `relation_types` | `Array(RelationType)` |
| `behaviors` | `Array(PackBehavior)` |
| `tools` | `Array(Tool)` |
| `policies` | `Array(PackPolicy)` |
| `prompts` | `Array(PackPrompt)` |
| `settings_schema` | `String` |
| `settings_builder` | `Proc(JSON::Any?, Hash(String, JSON::Any))` |
| `capabilities` | `Array(CapabilityDecl)` |

`Pack#prompt_manifest` returns `{name => {version, hash}}`.
`Chronicle::Pack` is a top-level alias for `Chronicle::Packs::Pack`.

### `Chronicle::Packs::ObjectType`

`name`, `description`, optional `validator : (String -> String)?`
(parses/normalizes object data JSON; attached to the graph at load time,
not retroactively).

### `Chronicle::Packs::RelationType`

`name`, `source_types`, `target_types`, `description`. Empty endpoint
lists mean "any".

### `Chronicle::Packs::PackPolicy`

`name`, `requires_approval` (object type names gated until
`runtime.approve_pack(...)`), `auto_apply`.

### `Chronicle::Packs::PackPrompt`

`name`, `version`, `body`, `content_hash` (SHA-256 of the body truncated
to 16 hex chars — the replay contract is the hash, not the version).
`PackPrompt.from_body(name, version, body)` and
`PackPrompt.compute_hash(body)`.

### `Chronicle::Packs::EmptySettings`

No-settings placeholder; includes `SettingsSchema` and
`JSON::Serializable`.

### `Chronicle::Packs::SettingsSchema` / `Chronicle::Packs::Settings`

Include `SettingsSchema` in a `JSON::Serializable` struct to get
`build_pack_settings(input)` (validation raising
`PackSettingsMissingError`) and `pack_settings_name`. `Settings` provides
canonicalization helpers.

### `Chronicle::Packs::CapabilityDecl`

`provider`, `capability`, `risk_class` (`low|medium|high|critical`),
`credential_ref`, `action_class` (`R0..R4` or `""`).

## Discovery

`Chronicle::Packs::Registry` is the Crystal analogue of Python
entry-point discovery: packs register when their module is required, and
`discover` is cached per process until `clear_discovery_cache`.

| Method | Signature |
| --- | --- |
| `Packs.discover` | `-> Array(DiscoveredPack)` |
| `Packs.load_by_name` | `(name : String) -> Pack` (raises `PackNotFoundError`) |
| `Packs.clear_discovery_cache` | `-> Nil` |
| `Packs.load_prompts_from_dir` | `(path : String) -> Array(PackPrompt)` |
| `Packs::Registry.register` | `(pack : Pack) -> Nil` |

### `Chronicle::Packs::DiscoveredPack`

`name`, `version`, `entry_point`, `pack`.

### Manifest

`Chronicle::Packs.load_manifest(path)` parses and schema-validates a
`manifest.toml` into a `PackManifest`; `verify_surface(manifest, pack)`
performs the two-way surface check; `compute_content_hash` /
`compute_bundle_hash` / `verify_bundle_hash` / `verify_content_hash`
implement the spec §4 walk. `Packs::PackManifestError` carries every
violation.

### Scaffolding

`Chronicle::Packs::Scaffold.scaffold_pack(target_dir, raw_name)` writes
the pack skeleton and returns the created root;
`normalize_pack_name(raw)` returns `{directory_name, module_name}`.

## Approvals + policies

### `Chronicle::Policy`

Legacy per-behavior write/tool allowlist
(`behavior`, `can_create`, `can_create_relation`, `can_call_tool`,
`requires_approval`). This is distinct from `Packs::PackPolicy`, which is
the pack-system policy.

### `Chronicle::Packs::PackPendingApproval`

A deferred object creation gated behind a policy approval: `id`, `kind`,
`object_type`, `data`, `reason`, `pack`. Rebuilt from the log on
load/fork; `Runtime#approve_pack(id)` materializes the object.
