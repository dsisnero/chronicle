# Errors

The `ActiveGraphError` hierarchy plus the cross-cutting helpers. For the
format spec and the events-not-exceptions principle see
[`docs/reference/errors.md`](../errors.md). For per-error recovery prose
see the error catalog page; the per-leaf Python pages are not ported (see
below).

## Hierarchy root

### `Chronicle::ActiveGraphError`

Root of every framework error (CONTRACT v1.0 #4), a subclass of
`ArgumentError`. Subclasses construct with a one-line summary plus the
structured fields `what_failed` / `why` / `how_to_fix` / `context`.
`#to_s` produces the locked format:

```text
<ErrorClass>: <one-line summary>

What failed:
  ...

Why:
  ...

How to fix:
  ...

More:
  https://docs.activegraph.ai/errors/<slug>
```

`#structured?`, `.doc_slug`, and `#doc_url` are part of the surface.
`ActiveGraphError.internal_bug_fields(...)` builds the uniform structured
fields for an internal-bug exception.

### `Chronicle::DomainError`

Base class for invalid inputs rejected by the deterministic core. Most
non-category leaves inherit from it and therefore remain
`ArgumentError`s for existing rescue sites.

## Category bases

| Category | Class |
| --- | --- |
| Configuration | `Chronicle::ConfigurationError` |
| Registration | `Chronicle::RegistrationError` |
| Execution | `Chronicle::ExecutionError` |
| Replay | `Chronicle::ReplayError` |
| Storage | `Chronicle::StorageError` |
| Pattern | `Chronicle::PatternError` (in `patterns.cr`) |
| Pack | `Chronicle::Packs::PackError` / `Chronicle::PackError` |

## Cross-cutting

`MissingOptionalDependency` is **not ported**: Chronicle's optional
dependencies are compile-time shards, not runtime extras. See
[`plans/parity.md`](../../../plans/parity.md).

## Replay

### `Chronicle::ReplayDivergenceError`

Raised when a strict replay or fork's event stream does not match the
recorded log. Structured constructor
`(event_id:, expected:, actual:)` builds a `kind` discriminator:
`prompt_hash_mismatch`, `embedding_hash_mismatch`, `length_mismatch`, or
`type_mismatch`. `ReplayDivergenceError.build_message(...)` is public.

## Pattern

- `Chronicle::UnsupportedPatternError` — invalid/unsupported Cypher
  subset.
- `Chronicle::PatternTypeError`.
- `Chronicle::InvalidActivateAfter` (in `packs/scheduler.cr`) — a bad
  `activate_after` value.

## Storage

| Class | Meaning |
| --- | --- |
| `Chronicle::NonSerializableEventError` | Encode-side JSON failure (fail-fast gate). |
| `Chronicle::CorruptedEventPayloadError` | Stored payload could not be decoded as JSON. |
| `Chronicle::DuplicateEventError` | Event id collision. |
| `Chronicle::EventNotFoundError` | Referenced event id does not exist. |
| `Chronicle::InvalidStoreURL` | Malformed/unsupported store URL. |
| `Chronicle::EventSequenceError` | Sequence must increase. |
| `Chronicle::CausalParentError` | `caused_by` parent missing. |
| `Chronicle::InvalidLogEncodingError` | Event-log file header/record invalid. |

`SchemaVersionMismatch` is **not ported** (the store schema version is
fixed and the reader tolerates additive tables). See
[`plans/parity.md`](../../../plans/parity.md).

## Execution

| Class | Notes |
| --- | --- |
| `Chronicle::LLMBehaviorError` | Carries `reason` + `payload_extras`. |
| `Chronicle::ToolError` | Carries `reason` + `payload_extras`. |
| `Chronicle::UnknownToolError` | LLM asked for an undeclared tool. |
| `Chronicle::ReservedFieldError` | Behavior injected a reserved data field. |
| `Chronicle::RuntimeContextRequiredError` | `ctx.*` called on an unbound context. |
| `Chronicle::PromoteConflictError` | Promote delta conflicted; nothing applied. |
| `Chronicle::PromoteLineageError` | Fork lineage does not hold. |
| `Chronicle::ApprovalError` | Approval request already exists / not found. |
| `Chronicle::GraphProjectionError` | Unknown object/patch or invalid projection event. |
| `Chronicle::DevOverrideError` | Invalid/forbidden dev override. |

`ApprovalNotFoundError`, `InvalidPatchLifecycleState`, and
`InternalEvaluatorError` are **not ported** as distinct classes; their
roles map to `ApprovalError`, `GraphProjectionError`, and (for the
framework-bug voice) the structured `ActiveGraphError.internal_bug_fields`
path. See [`plans/parity.md`](../../../plans/parity.md).

## Registration

| Class | Notes |
| --- | --- |
| `Chronicle::MissingProviderError` | LLM behavior without an LLM provider. |
| `Chronicle::MissingToolError` | Declared tool not registered. |
| `Chronicle::Packs::BehaviorNotFoundError` | `get_behavior` miss. |
| `Chronicle::Packs::AmbiguousBehaviorError` | Short-name lookup ambiguous. |
| `Chronicle::Packs::PackNotFoundError` | `load_by_name` miss. |
| `Chronicle::Packs::PackConflictError` | Two packs conflict on an identifier. |
| `Chronicle::Packs::PackVersionConflictError` | Same name, different version. |
| `Chronicle::InvalidRoutingPolicyError` / `NoRouteError` / `NoLocalTargetError` | Routing registration/lookup failures. |
| `Chronicle::ProviderNotAvailableError` / `Chronicle::ToolNameCollisionError` | Provider registry / tool-name wire collisions. |

`AmbiguousToolError`, `ToolNotFoundError`, and `InvalidToolRegistration`
are **not ported** as distinct classes; tool registration is validated by
the pack loader (`MissingToolError`, `PackConflictError`) and
`ToolNameCollisionError`. See [`plans/parity.md`](../../../plans/parity.md).

## Pack

- `Chronicle::Packs::PackSchemaViolation` — data failed a declared type's
  schema (`for_object`, `for_relation_source`, `for_relation_target`).
- `Chronicle::Packs::PackValidationError` — a `Pack(...)` argument was
  invalid.
- `Chronicle::Packs::PackSettingsMissingError` — settings failed
  validation.
- `Chronicle::Packs::PackPromptLoadError` — malformed/missing prompt
  frontmatter.
- `Chronicle::Packs::PackManifestError` — one or more manifest
  violations.

## Configuration

- `Chronicle::InvalidRuntimeConfiguration` — invalid caller config
  (including the cross-provider model mismatch shape).
- `Chronicle::IncompatibleRuntimeState` — operation not valid for the
  runtime's current backing (e.g. `fork` on a non-SQLite runtime).
- `Chronicle::OverrideNotAllowedError`, `Chronicle::ContextBudgetError`,
  `Chronicle::InvalidRoutingPolicyError`.

`InvalidArgumentType` is **not ported**; Crystal's type system rejects
invalid argument types at compile time. See
[`plans/parity.md`](../../../plans/parity.md).
