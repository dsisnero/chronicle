# Coding Guidelines

- Put library code in `src/` and tests in `spec/` (mirrored under
  `src/chronicle/` and `spec/chronicle/`).
- Use Crystal's formatter; do not hand-format around it (`make format`).
- Use Crystal idioms and best practices:
  - `JSON::Serializable` for fixed/typed schemas (event envelopes, entities),
    `JSON::Builder` for canonical/byte-stable output, `JSON::Any` for
    arbitrary data blobs, `JSON::PullParser` when streaming.
  - Prefer enum predicates and `case/in`; avoid `not_nil!` where flow analysis
    can narrow; use descriptive block parameter names.
- Packs use the annotation DSL, never Python-style decorators: `include
  Chronicle::Packs::DSL`, then `@[Behavior]` / `@[LLMBehavior]` /
  `@[RelationBehavior]` / `@[Tool]` / `@[ObjectType]` / `@[RelationType]`,
  closed by `pack(...)`. See [authoring packs](guides/authoring-packs.md).
- Object and relation data are canonical JSON strings, and event payloads are
  flat (`id`, `type`, `data`, `version`) rather than upstream's nested
  `object` map. Record this class of divergence in `plans/parity.md`.
- The event store is the sequencing authority — it stamps `sequence` on
  append — and `GraphProjection#emit` is the single mutation path, so
  `graph.events` is the complete per-run log.
- Add focused specs for public behavior and bug fixes, ported from the
  upstream `tests/` where they exist (red-green).
- Keep the public API small and documented; each `src/chronicle/*.cr` module
  has a doc comment explaining what it ports and from where.
- Keep user-facing behavior documented under `docs/` (concepts, guides,
  cookbook, reference, API) alongside the change.
- Avoid committing generated files or scratch output (`temp/`, caches, and
  build artifacts are ignored).
- Only routing must be deterministic; where Chronicle deliberately diverges
  from activegraph, record it in `plans/parity.md` and cover it with a spec.
