require "../spec_helper"

describe Chronicle::BehaviorRunner do
  it "runs matching behaviors in event, priority, and ID order" do
    event = Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: 1_u64,
      id: "evt_000001",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship"})
    )
    handler = ->(trigger : Chronicle::Event, _graph : Chronicle::GraphProjection) do
      [Chronicle::EffectRequest.new("effect-#{trigger.id}", Chronicle::EffectKind::Tool, %({"tool":"check"}))]
    end
    first = Chronicle::BehaviorRegistration.new("alpha", 10, "goal.created", handler)
    second = Chronicle::BehaviorRegistration.new("beta", 10, "goal.created", handler)
    high_priority = Chronicle::BehaviorRegistration.new("zeta", 5, "goal.created", handler)

    result = Chronicle::BehaviorRunner.new([second, first, high_priority]).run(
      [event],
      Chronicle::GraphProjection.empty
    )

    result.lifecycle.map(&.behavior_id).should eq(["zeta", "alpha", "beta"])
    result.effects.map(&.id).should eq([
      "effect-evt_000001",
      "effect-evt_000001",
      "effect-evt_000001",
    ])
  end

  it "suppresses a behavior that exceeds its fan-out limit" do
    event = Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: 1_u64,
      id: "evt_000001",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship"})
    )
    handler = ->(_trigger : Chronicle::Event, _graph : Chronicle::GraphProjection) do
      [
        Chronicle::EffectRequest.new("one", Chronicle::EffectKind::Tool, "{}"),
        Chronicle::EffectRequest.new("two", Chronicle::EffectKind::Tool, "{}"),
      ]
    end
    behavior = Chronicle::BehaviorRegistration.new("burst", 10, "goal.created", handler)
    limits = Chronicle::RunnerLimits.new(max_fan_out: 1)

    result = Chronicle::BehaviorRunner.new([behavior], limits).run([event], Chronicle::GraphProjection.empty)

    result.lifecycle.first.status.should eq(Chronicle::BehaviorStatus::Suppressed)
    result.effects.should be_empty
  end
end
