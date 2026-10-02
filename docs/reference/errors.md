# Errors reference catalog

Every exception the framework raises has a dedicated recovery page
upstream. In this Crystal port the error message still ends with a
`More:` link to its (upstream) page, and you should rarely need to visit
this catalog directly.

If you arrived here from an error message, follow the link the message
printed. If you're browsing — start with
[ReplayDivergenceError](api/errors.md#chroniclereplaydivergenceerror)
(the voice reference for the catalog) or
[UnsupportedPatternError](api/errors.md)
(the authoring guide for pattern subscriptions).

The hierarchy itself is documented at
[API reference: Errors](api/errors.md). The event payload reason-code
vocabulary is documented at [Reference: Reason codes](reason-codes.md).

!!! note "Per-error pages"
    The upstream catalog ships one page per leaf under
    `docs/reference/errors/*.md`. Those generated/expanded pages are
    **not ported** here. The Crystal surface and the mapping of
    unported leaves are documented in
    [`api/errors.md`](api/errors.md) and tracked in
    [`plans/parity.md`](../../plans/parity.md).

## By category

The category bases match the
[`ActiveGraphError` hierarchy](api/errors.md):

### ReplayError

- [`ReplayDivergenceError`](api/errors.md#chroniclereplaydivergenceerror)

### PatternError

- `UnsupportedPatternError`
- `PatternTypeError`
- `InvalidActivateAfter`

### StorageError

- `CorruptedEventPayloadError`
- `DuplicateEventError`
- `EventNotFoundError`
- `EventSequenceError`
- `CausalParentError`
- `InvalidLogEncodingError`
- `NonSerializableEventError`
- `InvalidStoreURL`

### ExecutionError

- `LLMBehaviorError`
- `ToolError`
- `UnknownToolError`
- `ReservedFieldError`
- `RuntimeContextRequiredError`
- `ApprovalError`
- `GraphProjectionError`
- `DevOverrideError`
- `PromoteConflictError`
- `PromoteLineageError`

### ConfigurationError

- `InvalidRuntimeConfiguration`
- `IncompatibleRuntimeState`
- `ContextBudgetError`
- `OverrideNotAllowedError`
- `InvalidRoutingPolicyError`

### RegistrationError

- `MissingProviderError`
- `MissingToolError`
- `ProviderNotAvailableError`
- `ToolNameCollisionError`
- `Packs::BehaviorNotFoundError`
- `Packs::AmbiguousBehaviorError`
- `Packs::PackNotFoundError`
- `Packs::PackConflictError`
- `Packs::PackVersionConflictError`

### PackError

- `Packs::PackValidationError`
- `Packs::PackSchemaViolation`
- `Packs::PackSettingsMissingError`
- `Packs::PackPromptLoadError`
- `Packs::PackManifestError`

### Internal (framework-bug voice)

- `ActiveGraphError.internal_bug_fields(...)` — Chronicle's normalized
  structured-fields helper for internal-bug raises. There is no separate
  `InternalEvaluatorError` class (see [`api/errors.md`](api/errors.md)).

## What's related

- [API reference: Errors](api/errors.md) — the class hierarchy and
  divergence notes.
- [Reference: Reason codes](reason-codes.md) — the stable
  `behavior.failed` / `tool.responded` / failed LLM attempt reason
  vocabulary.
- [`plans/parity.md`](../../plans/parity.md) — which upstream leaves are
  intentionally not ported.
