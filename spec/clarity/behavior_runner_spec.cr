require "../spec_helper"

describe Clarity::BehaviorRunner do
  it "runs matching behaviors in event, priority, and ID order" do
    event = Clarity::Event.new(
      schema_version: 1_u16,
      sequence: 1_u64,
      id: "evt_000001",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship"})
    )
    handler = ->(trigger : Clarity::Event, _graph : Clarity::GraphProjection) do
      [Clarity::EffectRequest.new("effect-#{trigger.id}", Clarity::EffectKind::Tool, %({"tool":"check"}))]
    end
    first = Clarity::BehaviorRegistration.new("alpha", 10, "goal.created", handler)
    second = Clarity::BehaviorRegistration.new("beta", 10, "goal.created", handler)
    high_priority = Clarity::BehaviorRegistration.new("zeta", 5, "goal.created", handler)

    result = Clarity::BehaviorRunner.new([second, first, high_priority]).run(
      [event],
      Clarity::GraphProjection.empty
    )

    result.lifecycle.map(&.behavior_id).should eq(["zeta", "alpha", "beta"])
    result.effects.map(&.id).should eq([
      "effect-evt_000001",
      "effect-evt_000001",
      "effect-evt_000001",
    ])
  end

  it "suppresses a behavior that exceeds its fan-out limit" do
    event = Clarity::Event.new(
      schema_version: 1_u16,
      sequence: 1_u64,
      id: "evt_000001",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"ship"})
    )
    handler = ->(_trigger : Clarity::Event, _graph : Clarity::GraphProjection) do
      [
        Clarity::EffectRequest.new("one", Clarity::EffectKind::Tool, "{}"),
        Clarity::EffectRequest.new("two", Clarity::EffectKind::Tool, "{}"),
      ]
    end
    behavior = Clarity::BehaviorRegistration.new("burst", 10, "goal.created", handler)
    limits = Clarity::RunnerLimits.new(max_fan_out: 1)

    result = Clarity::BehaviorRunner.new([behavior], limits).run([event], Clarity::GraphProjection.empty)

    result.lifecycle.first.status.should eq(Clarity::BehaviorStatus::Suppressed)
    result.effects.should be_empty
  end
end
