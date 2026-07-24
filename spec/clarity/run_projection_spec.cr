require "../spec_helper"

module RunProjectionSpecHelper
  extend self

  def event(sequence : UInt64, payload : String) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16,
      sequence: sequence,
      id: "evt_#{sequence}",
      type: "goal.created",
      actor: "user",
      caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload
    )
  end
end

describe Clarity::RunProjection do
  it "derives the current objective by folding goal-created events" do
    events = [
      RunProjectionSpecHelper.event(sequence: 1_u64, payload: %({"goal":"ship deterministic routing"})),
      RunProjectionSpecHelper.event(sequence: 2_u64, payload: %({"goal":"verify strict replay"})),
    ]

    projection = Clarity::RunProjection.replay(events)

    projection.objective.should eq("verify strict replay")
  end

  it "does not mutate an earlier projection when applying an event" do
    initial = Clarity::RunProjection.empty
    projected = initial.apply(RunProjectionSpecHelper.event(sequence: 1_u64, payload: %({"goal":"ship deterministic routing"})))

    initial.objective.should be_nil
    projected.objective.should eq("ship deterministic routing")
  end
end
