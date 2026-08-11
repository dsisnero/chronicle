require "../spec_helper"

private def lifecycle_event(type : String, id : String, sequence : UInt64) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: "runtime", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: %({}),
  )
end

describe Chronicle::RuntimeReason do
  describe ".lifecycle?" do
    it "treats behavior.*, relation_behavior.*, runtime.*, and context.read as lifecycle (upstream _is_lifecycle)" do
      Chronicle::RuntimeReason.lifecycle?(lifecycle_event("behavior.started", "e1", 1_u64)).should be_true
      Chronicle::RuntimeReason.lifecycle?(lifecycle_event("relation_behavior.started", "e2", 2_u64)).should be_true
      Chronicle::RuntimeReason.lifecycle?(lifecycle_event("runtime.idle", "e3", 3_u64)).should be_true
      Chronicle::RuntimeReason.lifecycle?(lifecycle_event("context.read", "e4", 4_u64)).should be_true
    end

    it "treats non-lifecycle events as not lifecycle" do
      Chronicle::RuntimeReason.lifecycle?(lifecycle_event("goal.created", "e1", 1_u64)).should be_false
      Chronicle::RuntimeReason.lifecycle?(lifecycle_event("object.created", "e2", 2_u64)).should be_false
    end
  end

  describe "ReplayEngine strict replay" do
    it "skips lifecycle events when comparing streams (a verify pass with tracing off does not diverge on context.read)" do
      # Recorded log: goal + behavior.started + context.read (tracing on).
      recorded = [
        lifecycle_event("goal.created", "evt_1", 1_u64),
        lifecycle_event("behavior.started", "evt_2", 2_u64),
        lifecycle_event("context.read", "evt_3", 3_u64),
      ]
      # Verify pass: tracing off — goal only, no lifecycle markers.
      emitted = [
        lifecycle_event("goal.created", "evt_1", 1_u64),
      ]

      result = Chronicle::ReplayEngine.new.replay(
        recorded_events: recorded,
        mode: Chronicle::ReplayMode::Strict,
        emitted_events: emitted,
      )
      result.projection.should be_a(Chronicle::GraphProjection)
    end
  end
end
