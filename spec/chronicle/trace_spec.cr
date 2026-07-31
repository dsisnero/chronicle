require "../spec_helper"

# Trace causal-chain specs. Ported from activegraph trace/causal.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

module TraceSpecHelper
  extend self

  def obj_event(seq : UInt64, id : String, type : String, data : String, caused_by : String?) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "object.created", actor: "test", caused_by: caused_by,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","data":#{data}}),
    )
  end

  def goal_event(seq : UInt64, id : String, goal : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: id,
      type: "goal.created", actor: "user", caused_by: nil,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"goal":"#{goal}"}),
    )
  end

  def chain_graph : Chronicle::GraphProjection
    events = [
      goal_event(1_u64, "goal_1", "ship it"),
      obj_event(2_u64, "doc#1", "doc", %({"title":"src"}), "goal_1"),
      obj_event(3_u64, "claim#1", "claim", %({"text":"x"}), "evt_2"),
    ]
    events.reduce(Chronicle::GraphProjection.empty) { |g, e| g.apply(e) }
  end
end

describe Chronicle::Trace do
  it "renders a causal chain from an object back to its goal" do
    g = TraceSpecHelper.chain_graph
    rendered = Chronicle::Trace.causal_chain(g.events, g, "claim#1")
    rendered.should contain("claim#1 (claim)")
    rendered.should contain("evt_3")
    rendered.should contain("evt_2")
    rendered.should contain("goal_1")
  end

  it "reports missing objects" do
    g = TraceSpecHelper.chain_graph
    Chronicle::Trace.causal_chain(g.events, g, "nope").should eq("(no such object: nope)")
  end

  it "detects cycles in the causal chain" do
    events = [
      TraceSpecHelper.obj_event(1_u64, "a#1", "task", %({}), nil),
    ]
    g = events.reduce(Chronicle::GraphProjection.empty) { |proj, e| proj.apply(e) }
    # self-caused event
    cyclic = Chronicle::Event.new(
      schema_version: 1_u16, sequence: 2_u64, id: "cycle_1",
      type: "object.created", actor: "test", caused_by: "cycle_1",
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"id":"b#1","type":"task","data":{}}),
    )
    g2 = g.apply(cyclic)
    rendered = Chronicle::Trace.causal_chain(g2.events, g2, "b#1")
    rendered.should contain("cycle")
  end
end
