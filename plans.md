# Clarity Design and Delivery Plan

## Purpose

Clarity is a log-primary, Sans-IO agent runtime in Crystal. It combines:

- **ActiveGraph:** the append-only event log is the authoritative history;
  projections, replay, fork, audit, and channel views derive from it.
- **Smista:** a deterministic router owns classification, provider/model
  selection, privacy/permission narrowing, and ordered fallback eligibility.
- **Crig:** provider adapters implement model and tool protocol details at the
  platform edge; Clarity owns policy, lifecycle, provenance, and replay.

```text
Channel adapters (TUI / CLI / HTTP / future clients)
  -> typed ChannelCommand
  -> log-primary runtime: validate, route, append effect request
  -> platform edge: resolve configured Crig provider and perform I/O
  -> durable effect result events
  -> projections / event subscriptions / channel renderers
```

No channel chooses a provider or executes a fallback. No core runtime code
opens a socket, reads credentials, or directly invokes a live provider.

## Active Detailed Plans

- [Implementation plan](plans/implementation.md): core event log, routing,
  replay, graph projection, Sans-IO HTTP/1, and acceptance gates.
- [Channel protocol plan](plans/channel_protocol.md): channel commands,
  provenance, route receipts, projections/subscriptions, provider execution,
  and transport adapters.
- [ActiveGraph parity plan](plans/parity.md): source-to-Crystal primitive
  mapping and intentional parity gaps.

These documents remain the detailed source of truth. This file is the overall
architecture and cross-plan delivery order.

## Non-Negotiable Design Rules

1. The event log is authoritative. Every material command, route, model/tool
   request/result, fallback, approval, cancellation, and non-fatal failure is
   a durable event with stable `actor` and `caused_by` provenance.
2. Routing is deterministic and router-owned. Clients may submit bounded
   intent/model preferences, but cannot select a provider, widen privacy/tool
   policy, or implement fallback logic.
3. Provider credentials, raw client identifiers, sockets, and provider SDK
   response objects stay outside the core and never enter canonical event
   payloads.
4. A `routing.decided` receipt precedes `llm.requested`; an executor consumes
   exactly that recorded target. A model is never silently substituted.
5. Strict replay never invokes a live model or tool. It consumes recorded
   results matched by the canonical request hash.

## Current State

Implemented foundations:

- Append-only event envelope, event stores, projections, replay/fork tools,
  deterministic routing, Sans-IO HTTP/1 framing, and a CML platform-edge
  coordination primitive.
- `Channel::SendMessage`, durable `command.accepted` provenance, idempotency,
  Bubble Tea ingress through `Runtime#handle`, and log-derived chat history.
- `routing.decided` receipts and an exact target-to-executor registry.
- Initial DeepSeek registration in the CLI when routing policy is active.

Known boundary violation to remove:

- `Runtime#drive_model` currently invokes `ModelExecutor` synchronously. The
  executor is injected, but live provider I/O must move fully to the platform
  edge before Clarity can claim an end-to-end Sans-IO execution path.

Provider-configuration progress:

- `ProviderConfig` now distinguishes provider kind from provider-instance ID,
  supports a credential environment reference and locality, and normalizes
  legacy built-in instance IDs to their kind.
- `ProviderCatalog` is the platform-edge availability snapshot used to exclude
  unconfigured, disabled, and missing-credential targets before routing. Its
  first slice intentionally has no discovery/capability metadata yet.
- `CrigProviderFactory` and a config-driven exact-target registry are in
  place. Concrete adapters construct Ollama, DeepSeek, OpenAI, Anthropic,
  Gemini, and named OpenAI-compatible endpoint models without I/O; CLI
  assembly now uses the configured catalog/registry when a routing policy is
  present. The legacy no-policy DeepSeek path remains for compatibility.

## Plan: Any Configured Crig Completion Provider

### Goal

Route to any Crig completion provider compiled into the application, including
DeepSeek, OpenAI, Anthropic, Gemini, Ollama, and configured OpenAI-compatible
endpoints. “Any” means a provider for which Crig has a completion adapter and
whose endpoint/credentials are configured and eligible; it does not imply that
an unknown provider name can be executed without a Crig adapter.

This follows Smista’s useful split, verified against its DeepWiki: configuration
enables providers and names models as `provider/model`; a provider kind is
separate from a stable provider-instance ID (for example,
`openai-compat:<name>`); endpoint instances and credentials are provider
configuration; and the router selects only known, credentialed, capable,
locality-eligible targets. In Smista, `Router::build` constructs these at the
edge (`crates/smista-router/src/router/build.rs`), while provider/model
interfaces keep discovery and execution behind a provider layer
(`crates/smista-providers/src/provider.rs` and `model.rs`).

### Provider Configuration Contract

Replace the DeepSeek-only CLI gate with a validated provider registry config.
Each entry has a stable provider-instance ID, a Crig provider kind, locality,
endpoint override, and a credential reference:

```yaml
providers:
  ollama:
    type: ollama
    base_url: http://127.0.0.1:11434
    local: true
  anthropic:
    type: anthropic
    api_key_env: ANTHROPIC_API_KEY
  gemini:
    type: gemini
    api_key_env: GEMINI_API_KEY
  openai-compat:local:
    type: openai_compatible
    base_url: http://127.0.0.1:8000/v1
    local: true
```

- Secrets resolve only at the platform edge from a credential reference or
  environment; configs and events contain no raw key.
- A route target uses the configured instance ID plus model ID. For example,
  `ollama/qwen2.5-coder:7b`, `anthropic/claude-sonnet`, or
  `openai-compat:local/llama-3.1-70b`.
- Provider type and instance ID are separate. This supports multiple
  OpenAI-compatible, Ollama, or gateway endpoints without ambiguity.
- Validate provider type, endpoint URI, model reference syntax, duplicate
  instances, and that every route/fallback names an enabled instance before a
  run starts.

### Delivery Sequence (Red-Green TDD)

#### 1. Config and catalog fixtures

- [ ] Write failing specs for DeepSeek, Ollama, Anthropic, Gemini, and a named
  OpenAI-compatible instance; cover missing credential, keyless local Ollama,
  invalid endpoint, disabled provider, and unknown route target.
- [ ] Extend `ProviderConfig` with provider type, credential reference, local
  flag, and endpoint metadata while preserving layered config precedence.
- [ ] Define a platform-edge `ProviderCatalog` snapshot: provider instance,
  model ID, locality, capability flags, context limit, known cost, and
  availability reason. Store the snapshot/reference used by each route receipt.
- [ ] Add model-discovery adapters where Crig/provider APIs support them;
  treat discovery as edge I/O and cache a timestamped snapshot. Static model
  configuration remains valid for providers that cannot list models.

#### 2. Strict Sans-IO model effects

- [ ] Write failing tests showing `Runtime` appends `llm.requested` and returns
  an effect request without calling a provider executor.
- [ ] Move `ModelExecutor` invocation into `CMLPlatformEdge` (or a dedicated
  effect worker). Feed a normalized result back as `llm.responded` or
  `llm.failed` with the request event as `caused_by`.
- [ ] Normalize only `choice`, token usage, provider/model identity, request
  hash, and safe error classification at the edge; keep raw provider payloads
  out of core events unless an explicit redacted artifact policy permits them.
- [ ] Prove strict replay uses the recorded response and performs zero provider
  calls.

#### 3. Crig provider factory registry

- [ ] Define a `CrigProviderFactory` per supported Crig completion provider.
  A factory validates one provider config and builds a `ModelExecutor` for a
  requested model without leaking provider SDK types into `Runtime`.
- [ ] Register factories for DeepSeek, OpenAI, Anthropic, Gemini, and Ollama;
  add OpenAI-compatible instances as a named factory/configuration family.
- [ ] Build `ProviderRegistry` from enabled configs and the catalog snapshot,
  not from a hard-coded CLI model. A missing registration emits/returns the
  explicit `provider_unavailable` outcome.
- [ ] Verify with deterministic fake factories that a target resolves to the
  intended factory and that no target can fall through to another provider.

#### 4. Deterministic execution fallback

- [ ] Extend the route receipt with its ordered eligible target list and the
  capability/privacy/permission facts used to produce it.
- [ ] On a retryable `llm.failed`, select only the next recorded eligible
  fallback; append `routing.fallback_selected` before the next
  `llm.requested`.
- [ ] Treat unknown instance, missing credential, insufficient context,
  unsupported capability, locality denial, and transient execution failure as
  distinct recorded exclusion/failure reasons. Only the latter, or a
  pre-recorded eligible alternative after a deterministic availability check,
  may advance the fallback list.
- [ ] Do not fallback for denied privacy, invalid configuration, unsupported
  capability, or non-retryable request errors. Record the reason.
- [ ] Add red-green fixtures for primary success, unavailable primary,
  retryable failure, exhausted fallbacks, local-only restrictions, and a
  privacy-blocked remote fallback.

#### 5. Channel and operator surfaces

- [ ] Let `route preview` display provider availability, capability mismatch,
  context exclusion, selected target, and ordered fallbacks using the same
  catalog snapshot as execution.
- [ ] Add CLI configuration/help for all provider instances; never require a
  DeepSeek key when a selected local/Ollama/other provider is sufficient.
- [ ] Add transcript/status projections for model request, retry, fallback,
  and terminal failure events.
- [ ] Add integration tests with local fakes only; no CI test may require live
  credentials, a live Ollama instance, or external network access.

## Acceptance Criteria

- A route to a configured Ollama, Anthropic, Gemini, DeepSeek, OpenAI, or
  named OpenAI-compatible model resolves through its exact Crig factory.
- A local Ollama route can run without an API key; cloud routes require their
  configured credential reference.
- Unsupported, disabled, missing-credential, unavailable, and capability-
  mismatched targets fail with an auditable deterministic reason.
- Provider calls occur only at the platform edge after `llm.requested` is
  durable; results/failures return as causal events.
- A fallback never bypasses route privacy, permissions, capability, or cost
  eligibility; it is always represented by `routing.fallback_selected`.
- The same policy, provider-catalog snapshot, context inventory, and command
  produce the same route receipt during replay verification.

## Research References

- [ActiveGraph events](https://docs.activegraph.ai/concepts/events/) and
  [event sinks](https://docs.activegraph.ai/guides/operating-in-production/):
  provenance, append-only authority, and post-persistence observation.
- [Smista configuration](https://docs.smista.ai/configuration/cli.html),
  [HTTP API](https://docs.smista.ai/api/http-api.html), and
  [architecture](https://docs.smista.ai/technical/architecture.html): enabled
  providers, endpoint instances, deterministic router ownership, capability
  eligibility, privacy/tool narrowing, and explainable routing.
- [Crig](https://github.com/dsisnero/crig): Crystal provider adapters used only
  by the platform-edge factory layer.
