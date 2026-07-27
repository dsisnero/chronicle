# Channel Protocol Plan

## Decision

Clarity will use two related, deliberately separate contracts:

1. **The event log is the durable agent protocol.** It is the authoritative,
   ordered history for runs, replay, fork, audit, and reconstruction.
2. **A versioned channel protocol is the live boundary.** TUI, CLI, HTTP, and
   future chat adapters submit typed commands and consume snapshots plus live
   events. It is not a replacement event store and may evolve independently
   of a Bubble Tea message or HTTP transport.

This follows the useful common shape in the systems reviewed:

- Codex exposes UI operations and an event stream over a bidirectional
  JSON-RPC app-server protocol; clients send work/approval operations and
  render UI-ready event notifications. Its core protocol explicitly separates
  submissions from events. [Codex protocol](https://github.com/openai/codex/blob/main/codex-rs/docs/protocol_v1.md)
  and [app-server overview](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md).
- OpenCode exposes durable sessions and snapshots through an OpenAPI HTTP
  server, while clients receive live updates through SSE. The TUI is a
  separate worker process rather than the owner of session state.
  [OpenCode DeepWiki architecture](https://deepwiki.com/anomalyco/opencode/2-core-application)
  and [server API](https://dev.opencode.ai/docs/server/).
- ActiveGraph treats the append-only per-run log as source of truth; its graph
  is a projection and its event sinks are observational adapters after an
  event is accepted and persisted. [ActiveGraph events](https://docs.activegraph.ai/concepts/events/)
  and [event sinks](https://docs.activegraph.ai/guides/operating-in-production/).
- ActiveGraph provenance is not optional metadata: `actor` identifies who
  emitted an event and `caused_by` makes its chain back to a root goal
  reconstructable. [ActiveGraph event structure](https://docs.activegraph.ai/concepts/events/).
- Smista keeps routing inside the router: clients express a request or a
  preference, while the router deterministically classifies, applies privacy
  and tool constraints, selects an eligible model/fallback, and returns an
  explanation. [Smista routing configuration](https://docs.smista.ai/configuration/cli.html)
  and [router API](https://docs.smista.ai/api/http-api.html).

## Boundaries

```text
Bubble Tea / HTTP / CLI / Slack
  -> ChannelCommand (versioned ingress DTO)
  -> Runtime command handler
  -> append durable domain events
  -> EventStore + deterministic projections
  -> Event subscription / snapshot response
  -> channel-specific renderer
```

`Tea::Msg`, `Bubbles::TextInput::Model`, ANSI output, HTTP requests, and SSE
frames stay at the outer edge. They must not be persisted or exposed as the
cross-channel contract.

## Proposed Public Types

Names are provisional until the Phase 0 tests establish the API.

```crystal
module Clarity
  module Channel
    alias Command = SendMessage | Approve | Reject | Cancel | PreviewRoute

    struct SendMessage
      getter command_id : String
      getter run_id : String
      getter content : String
      getter channel : String
      getter intent_hint : String?
      getter model_override : String?
    end

    struct Approve
      getter command_id : String
      getter run_id : String
      getter approval_id : String
      getter channel : String
    end

    struct Reject
      getter command_id : String
      getter run_id : String
      getter approval_id : String
      getter reason : String?
      getter channel : String
    end

    struct Cancel
      getter command_id : String
      getter run_id : String
      getter channel : String
    end

    # Read-only: never invokes a provider or appends a run event.
    struct PreviewRoute
      getter command_id : String
      getter run_id : String
      getter content : String
      getter intent_hint : String?
      getter model_override : String?
    end
  end
end
```

The command handler returns an acknowledgement containing the assigned event
ID/sequence. It does not return a mutable conversation object. The caller
obtains current state from a projection and receives subsequent state changes
through a subscription.

`intent_hint` and `model_override` are requests, not decisions. The core
router validates them against the policy; they may never widen a project
privacy or tool restriction. The channel never chooses a provider/model and
never filters context on its own.

## Provenance, Causality, and Privacy

Every event continues to use the existing envelope provenance:

- `actor` is a stable domain identity: `user`, `runtime`, a registered
  behavior ID, or a named adapter such as `channel.tui`. It is not an
  unbounded display label supplied by a remote client.
- `caused_by` links each derived event to the triggering event. A submitted
  message has a causal chain such as `command.accepted -> goal.created ->
  chat.message -> routing.decided -> llm.requested -> llm.responded ->
  chat.message`.
- `command_id`, `channel`, and an optional authenticated principal reference
  belong in the accepted-command payload. Store an opaque stable principal ID
  or hash, never bearer tokens, API keys, raw IP addresses, or device IDs.
- Routing records the policy version/content hash, configured target set and
  provider-capability snapshot needed to reproduce eligibility. It never
  writes provider credentials into the log.
- Context/privacy events record stable item IDs, classification and
  inclusion/exclusion reason. They do not duplicate sensitive content merely
  to explain that it was excluded. Rendering and transport redaction are
  separate from the canonical log policy.

This is the minimum provenance needed to answer: *who submitted this command,
which policy selected the effect, which event caused it, what context was
allowed, and which result became visible?*

## Event Vocabulary

Keep `chat.message` as the channel-neutral, durable transcript event added in
the current TUI work. Add these typed domain events as functionality is
implemented:

| Purpose | Event |
| --- | --- |
| Command accepted/rejected/deduplicated | `command.accepted`, `command.rejected`, `command.duplicate` |
| User/assistant transcript | `chat.message` with `role`, `content`, and optional message metadata |
| Work state | `run.started`, `run.idle`, `run.cancelled`, `runtime.budget_exhausted` |
| Deterministic route receipt | `routing.decided` with classification, policy hash, matched rule, eligible targets, selected target, fallbacks, privacy/context result, permissions, and cost range |
| Model/tool execution | `llm.requested`, `llm.responded`, `tool.requested`, `tool.responded` |
| Human gates | `approval.proposed`, `approval.granted`, `approval.rejected` |
| Non-fatal execution failure | `behavior.failed` or a scoped `run.failed` |

Every event must use the existing envelope fields (`schema_version`, sequence,
ID, actor, `caused_by`, timestamp, canonical JSON payload). The command ID is
recorded in the accepted event payload or causally linked command event so a
repeated network submission can be safely deduplicated.

`routing.decided` is emitted before `llm.requested`. `llm.requested` is
caused by that route receipt, and must contain the selected provider/model,
request hash, and route-receipt ID. On an eligible fallback, emit a new route
receipt or explicit `routing.fallback_selected` event before the new request;
never silently swap the model. This closes a current gap: Clarity presently
previews a route but does not yet make the resulting target control provider
execution.

## Projections and Subscriptions

- `ChatTranscriptProjection` folds only `chat.message` events into the
  rendered transcript. The current `TUI::Transcript` is its first, local
  implementation.
- `RunStatusProjection` folds lifecycle, model/tool, and approval events into
  `input`, `processing`, `awaiting_approval`, `idle`, `cancelled`, or `failed`.
- `Runtime#subscribe(after_sequence)` delivers events only after successful
  append and projection. It is an in-process interface initially; HTTP/SSE and
  JSON-RPC adapters serialize the same event DTO later.
- Reconnect uses snapshot + `after_sequence`, never a UI-owned history cache.
  This is the same snapshot-plus-live-stream pattern visible in Codex and
  OpenCode.
- A subscription receives only accepted, persisted events; it must not publish
  speculative UI state. Its envelope includes `run_id`, sequence, event ID,
  type, payload, actor, and `caused_by` so a client can detect gaps and recover
  from a snapshot.

## Routing Integration

The channel protocol must carry enough input for deterministic routing without
duplicating routing logic:

1. `SendMessage` supplies text, optional explicit intent/model preference,
   channel provenance, and references to available context—not provider
   credentials or a client-selected route.
2. The runtime snapshots the effective policy and provider capabilities, then
   calls `Routing::Router#preview` (or its eventual execution equivalent).
3. The runtime records `routing.decided`, including the deterministic trace,
   matched rule, selected and excluded context, required permissions, and
   ordered eligible fallback targets.
4. The effect executor uses *that recorded target*, not a hard-coded default.
   It records success/failure and selects the next already-eligible fallback
   deterministically when policy permits.
5. Tool requests are checked against the narrowed route permission set;
   `ask` becomes an `approval.proposed` event and `deny` becomes an audited
   refusal, not a channel-only dialog.

The precedence adopted from existing Clarity/Smista guidance remains:
explicit model override (if policy-valid), lower rule priority, greater
specificity, then declaration order; privacy restrictions and tool permissions
can only narrow at each later layer. All of those inputs and the outcome must
be represented in the route receipt for replay.

## Delivery Plan (Red-Green TDD)

### Phase 0 — Contracts and fixtures

- [ ] Add failing specs for channel command validation, schema versioning,
  command IDs, and duplicate command idempotency.
- [x] Define the initial `Channel::SendMessage` and acknowledgement types with
  no terminal/network dependencies.
- [x] Add a red-green ingress spec for command provenance, a causal chain, and
  duplicate command idempotency. Validation, schema-version, and privacy
  fixture coverage remain to be added.
- [ ] Define fixture logs covering send, approval, rejection, cancellation,
  model response, tool response, and failure.
- [ ] Add focused tests proving a transcript and run status can be rebuilt
  solely from those fixtures.
- [ ] Add provenance fixtures asserting actor stability, complete `caused_by`
  chains, command-id deduplication, and absence of credentials/raw client
  identifiers in persisted payloads.
- [ ] Add route-receipt fixtures asserting that the same command, policy hash,
  context inventory, and capability snapshot selects the same target and
  produces the same included/excluded context and permission set.

### Phase 1 — Command ingress

- [ ] Add `Runtime#handle(command)` as the only channel-facing mutation API.
- [x] Add the initial `Runtime#handle(Channel::SendMessage)` path. It appends
  `command.accepted`, then emits a causally linked `goal.created` and user
  `chat.message`; duplicate `(run_id, command_id)` submissions return the
  original acknowledgement without rerunning the model.
- [ ] Route every accepted message in the runtime, append `routing.decided`,
  and make the selected target drive provider execution rather than only a
  diagnostic preview.
- [x] Persist the initial deterministic `routing.decided` receipt before the
  model loop, including classification, selected provider/model, trace,
  context inclusion/exclusion, narrowed permissions, and cost estimate. The
  provider adapter still needs to execute the recorded target and fallbacks.
- [x] Add the `ModelExecutor` platform-edge seam. When configured, runtime
  passes the selected target from the receipt to the executor; a focused spec
  proves the target handoff. A registry that resolves real providers and a
  retry/fallback execution loop remain to be implemented.
- [x] Add an exact `(provider, model)` `ProviderRegistry`. It resolves a route
  target only when explicitly registered and raises `ProviderNotAvailableError`
  after the route receipt when no executor exists; it never falls back to the
  ambient model. Registering real provider clients and executing policy
  fallbacks remain to be implemented.
- [x] Register the CLI's configured DeepSeek completion model through a
  `FixedModelExecutor` when routing policy is active. Its provider-specific raw
  response is normalized at the platform edge; the core receives only choice,
  usage, and message ID. Additional provider registrations and execution
  fallback retries remain to be implemented.
- [ ] Implement `PreviewRoute` as a read-only response: it uses the same
  deterministic router but appends no run events and makes no provider call.
- [ ] Turn `Approve`, `Reject`, and `Cancel` into their corresponding domain
  events; do not mutate TUI state directly.
- [x] Deduplicate the initial `SendMessage` path by `(run_id, command_id)` and
  return the original acknowledgement on retry.
- [x] Replace direct `BubbleTeaModel` calls to `Runtime#run` with
  `Runtime#handle(Channel::SendMessage)`. The TUI mints stable per-session
  command IDs and uses the runtime run ID.

### Phase 2 — Live read model

- [ ] Extract `TUI::Transcript` into a reusable `ChatTranscriptProjection`.
- [ ] Add `RunStatusProjection` and display a projected processing/approval
  state in the Bubble Tea UI.
- [ ] Add `RouteReceiptProjection` for the UI/API to explain the chosen model,
  fallback, privacy exclusions, cost estimate, and required approvals without
  inspecting provider credentials or raw requests.
- [ ] Add an in-process subscription with bounded per-subscriber queues and
  explicit overflow/error behavior.
- [ ] Test that a late subscriber rebuilds from a snapshot then receives only
  new events; test that a slow renderer cannot block the sequencer.

### Phase 3 — Transport adapters

- [ ] Provide a Sans-IO JSON codec for channel commands, acknowledgements,
  snapshots, and events; add schema-version compatibility tests.
- [ ] Add an HTTP/SSE adapter at the platform edge: command POST, snapshot
  GET, and event stream GET. Keep sockets and fibers outside the core.
- [ ] Consider a JSON-RPC adapter only after the command/event schema is
  stable; it should be a transport mapping, not a second agent protocol.
- [ ] Make the Bubble Tea app a subscriber that renders projections and turns
  keys into channel commands.

### Phase 4 — Recovery and operations

- [ ] Persist run metadata and permit reopening a specified `run_id` instead
  of creating a new chat run on every CLI start.
- [ ] Add replay/fork tests proving transcript and status projections reproduce
  exactly from a historical prefix.
- [ ] Add redaction policy for observational transports without changing the
  canonical event log.
- [ ] Add a policy/configuration fingerprint migration strategy and reject
  strict replay when an event lacks the snapshots necessary to verify its
  original route.
- [ ] Document rate limits, subscription backpressure, authorization, and
  command ownership for multi-client access.

## Explicit Non-Goals

- Do not make Bubble Tea types or ANSI rendering part of the shared protocol.
- Do not persist ephemeral token deltas as a replacement for the canonical
  assistant message; support optional deltas later as transient events.
- Do not expose the EventStore directly as a remote write API.
- Do not make an HTTP/SSE or JSON-RPC transport a prerequisite for the
  in-process runtime contract.
