require "../spec_helper"

module GraphProjectionSpecHelper
  extend self

  def event(sequence : UInt64, id : String, type : String, payload : String, caused_by : String? = nil) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16,
      sequence: sequence,
      id: id,
      type: type,
      actor: "test",
      caused_by: caused_by,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload
    )
  end
end

describe Clarity::GraphProjection do
  it "folds typed objects and relations from an ordered event log" do
    object = GraphProjectionSpecHelper.event(
      1_u64,
      "evt_000001",
      "object.created",
      %({"id":"goal-1","type":"goal","data":{"text":"ship replay"}})
    )
    relation = GraphProjectionSpecHelper.event(
      2_u64,
      "evt_000002",
      "relation.created",
      %({"id":"rel-1","type":"causes","from_id":"goal-1","to_id":"goal-1"}),
      object.id
    )

    projection = Clarity::GraphProjection.replay([object, relation])

    projection.get_object("goal-1").not_nil!.type.should eq("goal")
    projection.get_object("goal-1").not_nil!.data.should eq(%({"text":"ship replay"}))
    projection.get_relation("rel-1").not_nil!.from_id.should eq("goal-1")
  end

  it "reports structural changes between projections" do
    first = GraphProjectionSpecHelper.event(
      1_u64,
      "evt_000001",
      "object.created",
      %({"id":"goal-1","type":"goal","data":{}})
    )
    second = GraphProjectionSpecHelper.event(
      2_u64,
      "evt_000002",
      "object.created",
      %({"id":"claim-1","type":"claim","data":{}}),
      first.id
    )

    before = Clarity::GraphProjection.replay([first])
    after = Clarity::GraphProjection.replay([first, second])

    before.diff(after).added_object_ids.should eq(["claim-1"])
  end
end
