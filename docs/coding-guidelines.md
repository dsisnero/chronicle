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
- Add focused specs for public behavior and bug fixes, ported from the
  upstream `tests/` where they exist (red-green).
- Keep the public API small and documented; each `src/chronicle/*.cr` module
  has a doc comment explaining what it ports and from where.
- Avoid committing generated files or scratch output (`temp/`, caches, and
  build artifacts are ignored).
- Only routing must be deterministic; where Clarity deliberately diverges from
  activegraph, record it in `plans/parity.md`.
