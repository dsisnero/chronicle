require "../spec_helper"

# GraphStore contract specs. Ported from activegraph
# tests/test_graph_store.py + activegraph/store/graph_conformance.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

module GraphStoreSpecHelper
  extend self

  def obj(id : String, type : String = "memo", data : String = %({"text":"hi","n":1}), version : Int64 = 1) : Clarity::GraphObject
    Clarity::GraphObject.new(id: id, type: type, data: data, version: version)
  end

  def rel(id : String, type : String, from : String, to : String) : Clarity::GraphRelation
    Clarity::GraphRelation.new(id: id, type: type, from_id: from, to_id: to)
  end

  def patch(id : String, target : String) : Clarity::Patch
    Clarity::Patch.new(
      id: id, target: target, op: Clarity::PatchOp::Update,
      value: %({"text":"new"}), expected_version: 1_i64, proposed_by: "test",
    )
  end
end

describe Clarity::InMemoryGraphStore do
  it "round-trips objects" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("obj_1"))
    got = store.get_object("obj_1")
    got.not_nil!.id.should eq("obj_1")
    got.not_nil!.type.should eq("memo")
    got.not_nil!.data.should eq(%({"text":"hi","n":1}))
    got.not_nil!.version.should eq(1_i64)
  end

  it "returns nil for unknown objects" do
    store = Clarity::InMemoryGraphStore.new
    store.get_object("nope").should be_nil
  end

  it "overwrites on put" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("obj_1", version: 1_i64))
    store.put_object(GraphStoreSpecHelper.obj("obj_1", version: 2_i64))
    store.all_objects.size.should eq(1)
    store.get_object("obj_1").not_nil!.version.should eq(2_i64)
  end

  it "removes objects and no-ops on unknown ids" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("obj_1"))
    store.remove_object("obj_1")
    store.get_object("obj_1").should be_nil
    store.remove_object("obj_1")
  end

  it "round-trips relations and patches" do
    store = Clarity::InMemoryGraphStore.new
    store.put_relation(GraphStoreSpecHelper.rel("rel_1", "links", "a", "b"))
    store.put_patch(GraphStoreSpecHelper.patch("patch_1", "a"))
    store.get_relation("rel_1").not_nil!.from_id.should eq("a")
    store.get_relation("rel_1").not_nil!.to_id.should eq("b")
    store.get_patch("patch_1").not_nil!.target.should eq("a")
    store.all_relations.size.should eq(1)
    store.all_patches.size.should eq(1)
  end

  it "clears all entities" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("o1"))
    store.put_relation(GraphStoreSpecHelper.rel("r1", "links", "o1", "o2"))
    store.put_patch(GraphStoreSpecHelper.patch("p1", "o1"))
    store.clear
    store.all_objects.should be_empty
    store.all_relations.should be_empty
    store.all_patches.should be_empty
  end

  it "finds objects by type" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("o1", type: "memo"))
    store.put_object(GraphStoreSpecHelper.obj("o2", type: "memo"))
    store.put_object(GraphStoreSpecHelper.obj("o3", type: "note"))
    store.find_objects.map(&.id).sort.should eq(["o1", "o2", "o3"])
    store.find_objects("memo").map(&.id).sort.should eq(["o1", "o2"])
    store.find_objects("note").map(&.id).should eq(["o3"])
    store.find_objects("nope").should be_empty
  end

  it "finds objects in a set of types (OR, single-pass order)" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("o1", type: "memo"))
    store.put_object(GraphStoreSpecHelper.obj("o2", type: "note"))
    store.put_object(GraphStoreSpecHelper.obj("o3", type: "memo"))
    store.put_object(GraphStoreSpecHelper.obj("o4", type: "task"))
    store.find_objects_in_types(["memo"]).map(&.id).should eq(["o1", "o3"])
    store.find_objects_in_types(["memo", "task"]).map(&.id).should eq(["o1", "o3", "o4"])
    store.find_objects_in_types([] of String).should be_empty
    store.find_objects_in_types(["nope"]).should be_empty
  end

  it "finds relations by AND filters without requiring endpoints to exist" do
    store = Clarity::InMemoryGraphStore.new
    store.put_relation(GraphStoreSpecHelper.rel("r1", "links", "a", "b"))
    store.put_relation(GraphStoreSpecHelper.rel("r2", "cites", "a", "c"))
    store.put_relation(GraphStoreSpecHelper.rel("r3", "links", "b", "a"))
    store.find_relations.map(&.id).sort.should eq(["r1", "r2", "r3"])
    store.find_relations(source: "a").map(&.id).sort.should eq(["r1", "r2"])
    store.find_relations(target: "a").map(&.id).sort.should eq(["r3"])
    store.find_relations(type: "links").map(&.id).sort.should eq(["r1", "r3"])
    store.find_relations(source: "a", type: "links").map(&.id).sort.should eq(["r1"])
    store.find_relations(source: "z").should be_empty
  end

  it "walks an undirected neighborhood with placeholder endpoints" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("o1"))
    store.put_object(GraphStoreSpecHelper.obj("o2"))
    store.put_object(GraphStoreSpecHelper.obj("o3"))
    store.put_relation(GraphStoreSpecHelper.rel("r1", "links", "o1", "p"))
    store.put_relation(GraphStoreSpecHelper.rel("r2", "links", "p", "o2"))
    store.put_relation(GraphStoreSpecHelper.rel("r3", "links", "o2", "o3"))

    objs, rels = store.neighborhood("o1", depth: 1)
    objs.map(&.id).sort.should eq(["o1"])
    rels.map(&.id).sort.should eq(["r1"])

    objs, rels = store.neighborhood("o1", depth: 2)
    objs.map(&.id).sort.should eq(["o1", "o2"])
    rels.map(&.id).sort.should eq(["r1", "r2"])

    objs, rels = store.neighborhood("o1", depth: 3)
    objs.map(&.id).sort.should eq(["o1", "o2", "o3"])
    rels.map(&.id).sort.should eq(["r1", "r2", "r3"])
  end

  it "returns empty for neighborhoods starting at an unknown id" do
    store = Clarity::InMemoryGraphStore.new
    objs, rels = store.neighborhood("missing")
    objs.should be_empty
    rels.should be_empty
  end

  it "handles cycles in neighborhood traversal" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("a"))
    store.put_object(GraphStoreSpecHelper.obj("b"))
    store.put_object(GraphStoreSpecHelper.obj("c"))
    store.put_relation(GraphStoreSpecHelper.rel("ab", "links", "a", "b"))
    store.put_relation(GraphStoreSpecHelper.rel("bc", "links", "b", "c"))
    store.put_relation(GraphStoreSpecHelper.rel("ca", "links", "c", "a"))

    objs, rels = store.neighborhood("a", depth: 1)
    objs.map(&.id).sort.should eq(["a", "b", "c"])
    rels.map(&.id).sort.should eq(["ab", "ca"])

    objs, rels = store.neighborhood("a", depth: 2)
    rels.map(&.id).sort.should eq(["ab", "bc", "ca"])
  end

  it "matches linear chains homomorphically including self-loops" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("a"))
    store.put_relation(GraphStoreSpecHelper.rel("r", "links", "a", "a"))
    chains = store.match_chain([nil, nil, nil] of String?, [{"links", "right"}, {"links", "right"}])
    chains.map { |c| {c.objects.map(&.id), c.relations.map(&.id)} }
      .should eq([{["a", "a", "a"], ["r", "r"]}])
  end

  it "matches one-hop chains in both directions with type filters" do
    store = Clarity::InMemoryGraphStore.new
    store.put_object(GraphStoreSpecHelper.obj("a", type: "memo"))
    store.put_object(GraphStoreSpecHelper.obj("b", type: "note"))
    store.put_relation(GraphStoreSpecHelper.rel("ab", "links", "a", "b"))

    right = store.match_chain([nil, nil] of String?, [{"links", "right"}])
    right.map { |c| {c.objects.map(&.id), c.relations.map(&.id)} }
      .should eq([{["a", "b"], ["ab"]}])

    left = store.match_chain([nil, nil] of String?, [{"links", "left"}])
    left.map { |c| {c.objects.map(&.id), c.relations.map(&.id)} }
      .should eq([{["b", "a"], ["ab"]}])

    store.match_chain(["memo", "note"], [{"links", "right"}]).size.should eq(1)
    store.match_chain(["memo", "memo"], [{"links", "right"}]).should be_empty
  end
end
