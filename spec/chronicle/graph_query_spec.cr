require "../spec_helper"

# Graph query API specs. Ported from activegraph tests/test_graph.py
# (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).

module GraphQuerySpecHelper
  extend self

  def obj_event(seq : UInt64, id : String, type : String, data : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","data":#{data}}),
    )
  end

  def rel_event(seq : UInt64, id : String, type : String, from : String, to : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "relation.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","from_id":"#{from}","to_id":"#{to}"}),
    )
  end

  def three_node_graph : Chronicle::GraphProjection
    seq = 1_u64
    events = [] of Chronicle::Event
    a = obj_event(seq, "task#1", "task", %({"k":"a"})); seq += 1
    b = obj_event(seq, "task#2", "task", %({"k":"b"})); seq += 1
    c = obj_event(seq, "task#3", "task", %({"k":"c"})); seq += 1
    ab = rel_event(seq, "rel_1", "depends_on", "task#1", "task#2"); seq += 1
    ac = rel_event(seq, "rel_2", "depends_on", "task#1", "task#3"); seq += 1
    bc = rel_event(seq, "rel_3", "blocks", "task#2", "task#3"); seq += 1
    ba = rel_event(seq, "rel_4", "depends_on", "task#2", "task#1"); seq += 1
    [a, b, c, ab, ac, bc, ba].reduce(Chronicle::GraphProjection.empty) { |g, e| g.apply(e) }
  end

  def graph(events : Array(Chronicle::Event)) : Chronicle::GraphProjection
    events.reduce(Chronicle::GraphProjection.empty) { |g, e| g.apply(e) }
  end

  def data_field(obj : Chronicle::GraphObject, key : String) : String
    JSON.parse(obj.data)[key].as_s
  end
end

describe Chronicle::GraphProjection do
  it "filters objects by type" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "claim#1", "claim", %({"text":"x"})),
      GraphQuerySpecHelper.obj_event(2_u64, "claim#2", "claim", %({"text":"y"})),
      GraphQuerySpecHelper.obj_event(3_u64, "task#1", "task", %({"title":"t"})),
    ])
    claims = g.objects(type: "claim")
    claims.map { |o| GraphQuerySpecHelper.data_field(o, "text") }.sort.should eq(["x", "y"])
    claims.all? { |o| o.type == "claim" }.should be_true
  end

  it "filters objects by where predicate" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "claim#1", "claim", %({"text":"x","confidence":0.9})),
      GraphQuerySpecHelper.obj_event(2_u64, "claim#2", "claim", %({"text":"y","confidence":0.4})),
    ])
    where = JSON.parse(%({"confidence": {">": 0.5}})).as_h
    high = g.objects(type: "claim", where: where)
    high.size.should eq(1)
    GraphQuerySpecHelper.data_field(high[0], "text").should eq("x")
  end

  it "objects with no kwargs returns every object" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "claim#1", "claim", %({"text":"x"})),
      GraphQuerySpecHelper.obj_event(2_u64, "task#1", "task", %({"title":"t"})),
    ])
    g.objects.map(&.id).sort.should eq(g.all_objects.map(&.id).sort)
  end

  it "objects and query return the same results" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "claim#1", "claim", %({"text":"x","confidence":0.9})),
      GraphQuerySpecHelper.obj_event(2_u64, "claim#2", "claim", %({"text":"y","confidence":0.4})),
      GraphQuerySpecHelper.obj_event(3_u64, "task#1", "task", %({"title":"t"})),
    ])
    where = JSON.parse(%({"confidence": {">": 0.5}})).as_h
    new_ids = g.objects(type: "claim", where: where).map(&.id)
    old_ids = g.query(object_type: "claim", where: where).map(&.id)
    new_ids.should eq(old_ids)
  end

  it "query alias still works with a positional argument" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "claim#1", "claim", %({"text":"x"})),
      GraphQuerySpecHelper.obj_event(2_u64, "task#1", "task", %({"title":"t"})),
    ])
    g.query("claim").map(&.id).should eq(["claim#1"])
  end

  it "filters objects by equality and membership operators in where" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "claim#1", "claim", %({"status":"open"})),
      GraphQuerySpecHelper.obj_event(2_u64, "claim#2", "claim", %({"status":"closed"})),
    ])
    open = g.objects(type: "claim", where: JSON.parse(%({"status": "open"})).as_h)
    open.map(&.id).should eq(["claim#1"])
    member = g.objects(type: "claim", where: JSON.parse(%({"status": {"in": ["open", "closed"]}})).as_h)
    member.map(&.id).sort.should eq(["claim#1", "claim#2"])
    not_member = g.objects(type: "claim", where: JSON.parse(%({"status": {"not in": ["closed"]}})).as_h)
    not_member.map(&.id).should eq(["claim#1"])
  end

  it "relations with no kwargs returns every relation" do
    g = GraphQuerySpecHelper.three_node_graph
    g.relations.map(&.id).sort.should eq(["rel_1", "rel_2", "rel_3", "rel_4"])
  end

  it "relations source only returns outgoing from source" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(source: "task#1")
    out.map(&.id).sort.should eq(["rel_1", "rel_2"])
    out.all? { |r| r.from_id == "task#1" }.should be_true
  end

  it "relations target only returns incoming to target" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(target: "task#2")
    out.map(&.id).should eq(["rel_1"])
    out.all? { |r| r.to_id == "task#2" }.should be_true
  end

  it "relations source and target returns the intersection" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(source: "task#1", target: "task#2")
    out.map(&.id).should eq(["rel_1"])
  end

  it "relations type only returns every relation of type" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(type: "blocks")
    out.map(&.id).should eq(["rel_3"])
    out.all? { |r| r.type == "blocks" }.should be_true
  end

  it "relations source and type returns outgoing of type" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(source: "task#1", type: "depends_on")
    out.map(&.id).sort.should eq(["rel_1", "rel_2"])
  end

  it "relations target and type returns incoming of type" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(target: "task#2", type: "depends_on")
    out.map(&.id).should eq(["rel_1"])
  end

  it "relations source, target, and type is most specific" do
    g = GraphQuerySpecHelper.three_node_graph
    out = g.relations(source: "task#1", target: "task#2", type: "depends_on")
    out.map(&.id).should eq(["rel_1"])
    g.relations(source: "task#1", target: "task#2", type: "blocks").should be_empty
  end

  it "get_relations alias supports outgoing, incoming, and both" do
    g = GraphQuerySpecHelper.three_node_graph
    g.get_relations(object_id: "task#1", direction: "outgoing").map(&.id).sort.should eq(["rel_1", "rel_2"])
    g.get_relations(object_id: "task#1", direction: "incoming").map(&.id).should eq(["rel_4"])
    g.get_relations(object_id: "task#1", direction: "both").map(&.id).sort.should eq(["rel_1", "rel_2", "rel_4"])
  end

  it "neighborhood walks to depth" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "task#1", "task", %({})),
      GraphQuerySpecHelper.obj_event(2_u64, "task#2", "task", %({})),
      GraphQuerySpecHelper.obj_event(3_u64, "task#3", "task", %({})),
      GraphQuerySpecHelper.rel_event(4_u64, "rel_1", "depends_on", "task#1", "task#2"),
      GraphQuerySpecHelper.rel_event(5_u64, "rel_2", "depends_on", "task#2", "task#3"),
    ])
    objs, rels = g.neighborhood("task#1", depth: 1)
    objs.map(&.id).sort.should eq(["task#1", "task#2"])
    rels.size.should eq(1)

    objs, rels = g.neighborhood("task#1", depth: 2)
    objs.map(&.id).sort.should eq(["task#1", "task#2", "task#3"])
    rels.size.should eq(2)
  end

  it "fetches a relation by id" do
    g = GraphQuerySpecHelper.three_node_graph
    g.get_relation("rel_2").not_nil!.from_id.should eq("task#1")
    g.get_relation("rel_2").not_nil!.to_id.should eq("task#3")
    g.get_relation("nope").should be_nil
  end

  it "finds objects in types and reports type presence" do
    g = GraphQuerySpecHelper.graph([
      GraphQuerySpecHelper.obj_event(1_u64, "task#1", "task", %({})),
      GraphQuerySpecHelper.obj_event(2_u64, "task#2", "task", %({})),
      GraphQuerySpecHelper.obj_event(3_u64, "doc#1", "doc", %({})),
    ])
    g.objects_in_types(["task"]).map(&.id).sort.should eq(["task#1", "task#2"])
    g.objects_in_types(["task", "doc"]).map(&.id).sort.should eq(["doc#1", "task#1", "task#2"])
    g.has_object_of_type("task").should be_true
    g.has_object_of_type("note").should be_false
  end
end
