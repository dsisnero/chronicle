# Policies

A policy is a runtime-attached rule that gates changes to the graph
before they land. A behavior proposing a graph mutation under a policy
doesn't get a direct apply — the change becomes a pending **approval**.
An operator (or an auto-approve setting) then approves the proposal, and
the change lands.

Policies are how the framework lets an operator sit in the loop without
rewriting the behavior. The behavior says "I want to add this memo"; the
policy says "memos require explicit approval"; the operator says "yes,
approve it." The same behavior runs in dev (auto-approve) and prod
(explicit-approve) without code changes.

## What gets gated

Two operations can be policy-gated:

- **Object proposals via `ctx.propose_object(type, data, reason:)`.**
  Instead of an immediate `add_object`, the framework records a pending
  approval and emits `approval.proposed`. The object lands only when the
  approval is granted.
- **Tools.** A `PackPolicy` can list tool names whose calls require
  approval; the runtime routes such calls through pending approval
  before execution.

Object proposals are the more common shape. The Diligence pack's
`memo_approval` policy is the canonical example: the pack declares which
object types require approval, and the operator decides per-instance.

Not every change is policy-gated. Direct `graph.add_object`,
`graph.patch_object`, and `graph.emit` calls land immediately; they're
for changes the behavior author decided don't need operator review. The
behavior chooses by calling the proposal method instead of the direct
method.

## The approval lifecycle

```text
            proposed ──approve──> granted
```

A proposed approval becomes granted exactly once (via
`runtime.approve_pack(id, approved_by:)` for pack approvals, or
`runtime.approve(request_id)` for edge `ApprovalRequest`s). Approving an
id that isn't pending raises `ApprovalError` — the approval id is
consumed by the transition.

Each transition emits an event:

- `approval.proposed` — carries the proposal kind (`object`), the type,
  the data, the reason from the proposing behavior, and the pack that
  owns the gating policy.
- `approval.granted` — carries the approval id, the approver identity,
  and the object type.

The events sit in the log alongside everything else. Downstream
behaviors can subscribe to them; replay reconstructs the full
proposal-and-decision sequence; the trace renders them.

**Divergence:** upstream also defines an `approval.denied` event and a
`runtime.deny(...)` call. Chronicle does not emit `approval.denied`; the
edge `ApprovalAdapter` can resolve a request as denied
(`ApprovalDecision.new(id, approved: false)`), but a pack gate is either
approved or left pending. See
[`plans/parity.md`](../../plans/parity.md).

## Declaring policies

Packs declare policies in the `pack(...)` macro:

```crystal
pack(
  name: "diligence",
  version: "0.1.0",
  settings_schema: Settings,
  policies: [
    Chronicle::Packs::PackPolicy.new(
      name: "memo_approval",
      requires_approval: ["memo"]
    )
  ]
)
```

`requires_approval` lists the object types the policy gates.
`PackPolicy` also carries an `auto_apply` list; the pack's own
`settings_schema` boolean controls auto-approve behavior (the Diligence
pack uses `auto_approve_memos`). When the setting is `true`, the
framework approves every proposal automatically and the behavior runs as
if the policy weren't there. When `false`, every proposal pauses until
an operator decides.

The pack ships with the policies; the runtime instance decides
auto-approve via its pack settings. That separation lets one pack run in
different approval modes across environments.

## How a behavior proposes

A behavior that wants its change to flow through a policy calls
`ctx.propose_object` instead of `graph.add_object`:

```crystal
@[Behavior(name: "memo_synthesizer", on: ["object.created"],
  where: {"type" => "contradiction"})]
def memo_synthesizer(event : Chronicle::Event,
                     graph : Chronicle::GraphProjection,
                     ctx : Chronicle::Packs::BehaviorContext,
                     settings : Diligence::Settings)
  memo_payload = %({"title":"Diligence memo","body":"..."})
  if settings.auto_approve_memos?
    graph.add_object("memo", memo_payload)
  else
    ctx.propose_object("memo", memo_payload,
      reason: "diligence run complete")
  end
end
```

The propose call returns an approval id. The runtime decides whether to
apply immediately (auto-approve setting is `true`) or queue the
proposal (setting is `false`). Either way, the behavior body completes;
the approval lifecycle continues independently.

If the behavior tries `ctx.propose_object` outside a runtime-bound
context — typically a direct handler-call test — it raises
`RuntimeContextRequiredError`.

## The operator-facing recovery

When auto-approve is off, the operator drives the lifecycle:

```crystal
# Pack-gated object proposals.
runtime.pack_pending_approvals.each do |pa|
  puts "#{pa.id}  #{pa.kind}  #{pa.object_type}  #{pa.reason}"
end

runtime.approve_pack(approval_id, approved_by: "operator-jane")
# The deferred object is materialized on approval.

# Edge approval requests (file write / shell / network / restricted ctx):
runtime.pending_approvals.each do |req|
  puts "#{req.id}  #{req.kind}  #{req.summary}"
end
runtime.approve(request_id)
```

The CLI surface for production approval workflows belongs with the
operator tooling; see the CLI reference as it is ported.

## The events-not-exceptions principle applied

A denial is a state, not an exception. A behavior whose proposal is
never approved doesn't see a raised exception — it stays pending, and
downstream code sees the outcome in the event log. The runtime
continues.

The exception case is misuse of the primitive — passing a nonexistent
approval id to `approve` / `approve_pack` — which raises `ApprovalError`.
See [`failure-model`](failure-model.md) for the broader principle.

## What's related

- [`patches`](patches.md) — the durable-change primitive that policies
  gate. Approvals and patches share the proposed-and-decided shape;
  patches are the lower-level primitive.
- [`behaviors`](behaviors.md) — where `ctx.propose_object` is called
  from.
- [`failure-model`](failure-model.md) — why denials are events.
- [`type-system`](type-system.md) — `PackPolicy` and other pack value
  objects.
