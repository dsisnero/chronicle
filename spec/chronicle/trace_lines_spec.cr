require "../spec_helper"

# Trace line rendering (CONTRACT #18 — format is the public contract).
# Ported from activegraph.trace.printer. Chronicle stores flat payloads
# (object.created carries id/type/data at top level), so the formatters
# read Chronicle's flat shapes.

def trace_event(type : String, payload : String) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: "evt_1",
    type: type, actor: "runtime", caused_by: nil, timestamp: Time.utc,
    payload: payload,
  )
end

describe Chronicle::Trace do
  it "renders goal.created with the actor and quoted goal" do
    e = trace_event("goal.created", %({"goal": "build a thing"}))
    Chronicle::Trace.format_event(e).should eq("[goal.created]            user: \"build a thing\"")
  end

  it "pads short tags to the 26-char tag column" do
    e = trace_event("goal.created", %({"goal": "g"}))
    line = Chronicle::Trace.format_event(e)
    line.index("]").not_nil!.should be <= 26
  end

  it "renders object.created from the flat id/type/data payload" do
    e = trace_event("object.created", %({"id": "task#1", "type": "task", "data": {"title": "T"}, "version": 1}))
    Chronicle::Trace.format_event(e).should eq("[object.created]          task#1 \"T\"")
  end

  it "renders object.removed from the flat id payload" do
    e = trace_event("object.removed", %({"id": "task#1"}))
    Chronicle::Trace.format_event(e).should eq("[object.removed]          task#1")
  end

  it "renders relation.created from the flat from_id/to_id/type payload" do
    e = trace_event("relation.created", %({"id": "rel#1", "type": "depends_on", "from_id": "a", "to_id": "b"}))
    Chronicle::Trace.format_event(e).should eq("[relation.created]        a --depends_on--> b")
  end

  it "renders behavior.started with matched object id" do
    e = trace_event("behavior.started", %({"behavior": "worker", "event_id": "evt_0", "triggering_object_id": "task#1"}))
    Chronicle::Trace.format_event(e).should eq("[behavior.started]        worker  (matched task#1)")
  end

  it "renders behavior.failed with exception type and message" do
    e = trace_event("behavior.failed", %({"behavior": "worker", "event_id": "evt_0", "exception_type": "RuntimeError", "message": "boom"}))
    Chronicle::Trace.format_event(e).should eq("[behavior.failed]         worker: RuntimeError: boom")
  end

  it "renders llm.requested with event id, behavior, model, tokens estimate and budget" do
    e = trace_event("llm.requested", %({"event_id": "evt_1", "behavior": "extractor", "model": "claude-sonnet-4-5", "estimated_input_tokens": 100, "budget_remaining_usd": "0.500"}))
    Chronicle::Trace.format_event(e).should eq(
      "[llm.requested]           evt_1  extractor  model=claude-sonnet-4-5 tokens_in~100 budget_remaining=$0.500"
    )
  end

  it "renders pack.loaded with the structural summary" do
    e = trace_event("pack.loaded", %({"name": "diligence", "version": "0.1.0", "object_types": ["task"], "relation_types": [], "behaviors": ["a", "b"], "tools": [], "policies": [], "prompts": {}}))
    Chronicle::Trace.format_event(e).should eq("[pack.loaded]             diligence v0.1.0 (1 object_type, 2 behaviors)")
  end

  it "falls back to event.emitted for custom events" do
    e = trace_event("custom.type", %({"foo": "bar"}))
    Chronicle::Trace.format_event(e).should eq("[event.emitted]           custom.type foo=bar")
  end

  it "renders patch.applied with per-field lines" do
    e = trace_event("patch.applied", %({"target": "task#1", "diff": {"title": {"old": "A", "new": "B"}}}))
    Chronicle::Trace.format_event(e).should eq("[patch.applied]           task#1 title: A -> B")
  end

  it "renders patch.applied with (no change) when diff is empty" do
    e = trace_event("patch.applied", %({"target": "task#1", "diff": {}}))
    Chronicle::Trace.format_event(e).should eq("[patch.applied]           task#1 (no change)")
  end

  it "renders patch.proposed with target, op, and proposer" do
    e = trace_event("patch.proposed", %({"patch": {"target": "task#1", "op": "update", "proposed_by": "worker"}}))
    Chronicle::Trace.format_event(e).should eq("[patch.proposed]          task#1 update by worker")
  end

  it "renders patch.rejected with patch id and reason" do
    e = trace_event("patch.rejected", %({"patch_id": "p_1", "reason": "policy blocked"}))
    Chronicle::Trace.format_event(e).should eq("[patch.rejected]          p_1: policy blocked")
  end

  it "renders promote.applied with delta counts and fork point" do
    e = trace_event("promote.applied", %({"from_run": "run_a", "objects_created": ["o1"], "objects_patched": [], "objects_removed": [], "relations_created": [], "relations_removed": [], "forked_at_event": "evt_9"}))
    Chronicle::Trace.format_event(e).should eq("[promote.applied]         run_a -> here (+1) forked_at=evt_9")
  end

  it "renders promote.applied with empty delta" do
    e = trace_event("promote.applied", %({"from_run": "run_a", "objects_created": [], "objects_patched": [], "objects_removed": [], "relations_created": [], "relations_removed": [], "forked_at_event": "evt_9"}))
    Chronicle::Trace.format_event(e).should eq("[promote.applied]         run_a -> here (empty delta) forked_at=evt_9")
  end
end
