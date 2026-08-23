require "../spec_helper"

# GraphProjection ↔ GraphStore delegation specs. Mirrors the Graph-side checks
# from activegraph tests/test_graph_store.py (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).

module GraphProjectionStoreSpecHelper
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
end

describe Chronicle::GraphProjection do
  it "accepts an injected GraphStore and writes through it on apply" do
    store = Chronicle::InMemoryGraphStore.new
    g = Chronicle::GraphProjection.new(store: store)
    g = g.apply(GraphProjectionStoreSpecHelper.obj_event(1_u64, "task#1", "task", %({"title":"x"})))
    store.get_object("task#1").should_not be_nil
    g.get_object("task#1").not_nil!.type.should eq("task")
  end

  it "delegates reads to the injected store" do
    store = Chronicle::InMemoryGraphStore.new
    store.put_object(Chronicle::GraphObject.new(id: "task#1", type: "task", data: "{}"))
    store.put_relation(Chronicle::GraphRelation.new(id: "rel_1", type: "links", from_id: "task#1", to_id: "task#2"))
    g = Chronicle::GraphProjection.new(store: store)
    g.get_object("task#1").not_nil!.type.should eq("task")
    g.all_objects.map(&.id).should eq(["task#1"])
    g.all_relations.map(&.id).should eq(["rel_1"])
    g.match_chain([nil] of String?, [] of {String, String}).size.should eq(1)
    objs, rels = g.neighborhood("task#1", depth: 1)
    objs.map(&.id).should eq(["task#1"])
    rels.map(&.id).should eq(["rel_1"])
  end

  it "replays deterministically regardless of backend instance" do
    events = [
      GraphProjectionStoreSpecHelper.obj_event(1_u64, "task#1", "task", %({"title":"a"})),
      GraphProjectionStoreSpecHelper.obj_event(2_u64, "task#2", "task", %({"title":"b"})),
      GraphProjectionStoreSpecHelper.rel_event(3_u64, "rel_1", "links", "task#1", "task#2"),
    ]
    a = Chronicle::GraphProjection.replay(events)
    b = Chronicle::GraphProjection.replay(events)
    a.all_objects.map(&.id).sort.should eq(b.all_objects.map(&.id).sort)
    a.all_relations.map(&.id).sort.should eq(b.all_relations.map(&.id).sort)
    a.diff(b).added_object_ids.should be_empty
    a.diff(b).removed_object_ids.should be_empty
  end

  it "round-trips patch flow through the store" do
    store = Chronicle::InMemoryGraphStore.new
    g = Chronicle::GraphProjection.new(store: store)
      .apply(GraphProjectionStoreSpecHelper.obj_event(1_u64, "memo#1", "memo", %({"text":"first"})))
    result = g.patch_object("memo#1", %({"text":"second"}))
    result.graph.get_object("memo#1").not_nil!.data.should eq(%({"text":"second"}))
    result.graph.get_object("memo#1").not_nil!.version.should eq(2_i64)
    store.get_object("memo#1").not_nil!.version.should eq(2_i64)
  end
end
