require "../spec_helper"

# Reusable GraphStore contract suite. Ported from activegraph
# activegraph/store/graph_conformance.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
# A backend gets full coverage by invoking `GraphStoreConformance.define_tests`
# with an expression that yields a fresh, empty store inside each test.

module GraphStoreConformanceFixture
  extend self

  def obj(id : String, type : String = "memo", data : String = %({"text":"hello #{id}","n":1}), version : Int64 = 1) : Clarity::GraphObject
    Clarity::GraphObject.new(id: id, type: type, data: data, version: version)
  end

  def rel(id : String, source : String, target : String, type : String = "links") : Clarity::GraphRelation
    Clarity::GraphRelation.new(id: id, type: type, from_id: source, to_id: target)
  end

  def patch(id : String, target : String, status : Clarity::PatchState = Clarity::PatchState::Proposed) : Clarity::Patch
    Clarity::Patch.new(
      id: id, target: target, op: Clarity::PatchOp::Update,
      value: %({"text":"new"}), expected_version: 1_i64,
      proposed_by: "test", status: status,
    )
  end

  def chain_ids(chains : Array(Clarity::ChainMatch))
    chains.map { |chain| {chain.objects.map(&.id), chain.relations.map(&.id)} }.sort
  end
end

module GraphStoreConformance
  # `store_factory` must be an expression producing a fresh, empty GraphStore.
  macro define_tests(store_factory)
    # ---- objects ----

    it "round-trips objects" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("obj_1"))
      got = store.get_object("obj_1").not_nil!
      got.id.should eq("obj_1")
      got.type.should eq("memo")
      got.data.should eq(%({"text":"hello obj_1","n":1}))
      got.version.should eq(1_i64)
    end

    it "returns nil for unknown objects" do
      store = {{store_factory}}
      store.get_object("nope").should be_nil
    end

    it "overwrites an object on put" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("obj_1", version: 1_i64))
      store.put_object(GraphStoreConformanceFixture.obj("obj_1", version: 2_i64))
      got = store.get_object("obj_1").not_nil!
      got.version.should eq(2_i64)
      store.all_objects.size.should eq(1)
    end

    it "removes objects and no-ops on unknown ids" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("obj_1"))
      store.remove_object("obj_1")
      store.get_object("obj_1").should be_nil
      store.remove_object("obj_1")
    end

    it "enumerates all objects" do
      store = {{store_factory}}
      store.all_objects.should be_empty
      store.put_object(GraphStoreConformanceFixture.obj("obj_1"))
      store.put_object(GraphStoreConformanceFixture.obj("obj_2"))
      store.all_objects.map(&.id).sort.should eq(["obj_1", "obj_2"])
    end

    # ---- relations ----

    it "round-trips relations" do
      store = {{store_factory}}
      store.put_relation(GraphStoreConformanceFixture.rel("rel_1", "obj_1", "obj_2"))
      got = store.get_relation("rel_1").not_nil!
      got.from_id.should eq("obj_1")
      got.to_id.should eq("obj_2")
      got.type.should eq("links")
    end

    it "removes relations and enumerates the rest" do
      store = {{store_factory}}
      store.put_relation(GraphStoreConformanceFixture.rel("rel_1", "a", "b"))
      store.put_relation(GraphStoreConformanceFixture.rel("rel_2", "b", "c"))
      store.all_relations.map(&.id).sort.should eq(["rel_1", "rel_2"])
      store.remove_relation("rel_1")
      store.get_relation("rel_1").should be_nil
      store.all_relations.map(&.id).should eq(["rel_2"])
    end

    # ---- patches ----

    it "round-trips patches" do
      store = {{store_factory}}
      store.put_patch(GraphStoreConformanceFixture.patch("patch_1", "obj_1"))
      got = store.get_patch("patch_1").not_nil!
      got.target.should eq("obj_1")
      got.op.should eq(Clarity::PatchOp::Update)
      got.status.should eq(Clarity::PatchState::Proposed)
    end

    it "overwrites a patch status on put" do
      store = {{store_factory}}
      store.put_patch(GraphStoreConformanceFixture.patch("patch_1", "obj_1", status: Clarity::PatchState::Proposed))
      store.put_patch(GraphStoreConformanceFixture.patch("patch_1", "obj_1", status: Clarity::PatchState::Applied))
      got = store.get_patch("patch_1").not_nil!
      got.status.should eq(Clarity::PatchState::Applied)
      store.all_patches.size.should eq(1)
    end

    # ---- lifecycle ----

    it "clears all entities" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("obj_1"))
      store.put_relation(GraphStoreConformanceFixture.rel("rel_1", "obj_1", "obj_2"))
      store.put_patch(GraphStoreConformanceFixture.patch("patch_1", "obj_1"))
      store.clear
      store.all_objects.should be_empty
      store.all_relations.should be_empty
      store.all_patches.should be_empty
    end

    # ---- query hooks ----

    it "finds objects by type" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("o1", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("o2", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("o3", type: "note"))
      store.find_objects.map(&.id).sort.should eq(["o1", "o2", "o3"])
      store.find_objects("memo").map(&.id).sort.should eq(["o1", "o2"])
      store.find_objects("note").map(&.id).should eq(["o3"])
      store.find_objects("nope").should be_empty
    end

    it "finds objects in a set of types (OR, single-pass order)" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("o1", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("o2", type: "note"))
      store.put_object(GraphStoreConformanceFixture.obj("o3", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("o4", type: "task"))
      store.find_objects_in_types(["memo"]).map(&.id).should eq(["o1", "o3"])
      store.find_objects_in_types(["memo", "task"]).map(&.id).should eq(["o1", "o3", "o4"])
      store.find_objects_in_types(["task", "memo", "nope"]).map(&.id).should eq(["o1", "o3", "o4"])
      store.find_objects_in_types([] of String).should be_empty
      store.find_objects_in_types(["nope", "gone"]).should be_empty
    end

    it "finds relations by AND filters without requiring endpoints to exist" do
      store = {{store_factory}}
      store.put_relation(GraphStoreConformanceFixture.rel("r1", "a", "b", type: "links"))
      store.put_relation(GraphStoreConformanceFixture.rel("r2", "a", "c", type: "cites"))
      store.put_relation(GraphStoreConformanceFixture.rel("r3", "b", "a", type: "links"))
      store.find_relations.map(&.id).sort.should eq(["r1", "r2", "r3"])
      store.find_relations(source: "a").map(&.id).sort.should eq(["r1", "r2"])
      store.find_relations(target: "a").map(&.id).sort.should eq(["r3"])
      store.find_relations(type: "links").map(&.id).sort.should eq(["r1", "r3"])
      store.find_relations(source: "a", type: "links").map(&.id).sort.should eq(["r1"])
      store.find_relations(source: "a", target: "b").map(&.id).sort.should eq(["r1"])
      store.find_relations(source: "z").should be_empty
    end

    it "returns empty neighborhoods for unknown or placeholder-only starts" do
      store = {{store_factory}}
      store.put_relation(GraphStoreConformanceFixture.rel("r1", "ghost", "other"))
      objs, rels = store.neighborhood("missing")
      objs.should be_empty
      rels.should be_empty
      objs, rels = store.neighborhood("ghost")
      objs.should be_empty
      rels.should be_empty
    end

    it "walks a zero-depth neighborhood" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("o1"))
      store.put_object(GraphStoreConformanceFixture.obj("o2"))
      store.put_relation(GraphStoreConformanceFixture.rel("r1", "o1", "o2"))
      objs, rels = store.neighborhood("o1", depth: 0)
      objs.map(&.id).should eq(["o1"])
      rels.should be_empty
    end

    it "walks an undirected neighborhood with placeholder endpoints" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("o1"))
      store.put_object(GraphStoreConformanceFixture.obj("o2"))
      store.put_object(GraphStoreConformanceFixture.obj("o3"))
      store.put_relation(GraphStoreConformanceFixture.rel("r1", "o1", "p"))
      store.put_relation(GraphStoreConformanceFixture.rel("r2", "p", "o2"))
      store.put_relation(GraphStoreConformanceFixture.rel("r3", "o2", "o3"))

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

    it "handles cycles in neighborhood traversal" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("a"))
      store.put_object(GraphStoreConformanceFixture.obj("b"))
      store.put_object(GraphStoreConformanceFixture.obj("c"))
      store.put_relation(GraphStoreConformanceFixture.rel("ab", "a", "b"))
      store.put_relation(GraphStoreConformanceFixture.rel("bc", "b", "c"))
      store.put_relation(GraphStoreConformanceFixture.rel("ca", "c", "a"))

      objs, rels = store.neighborhood("a", depth: 1)
      objs.map(&.id).sort.should eq(["a", "b", "c"])
      rels.map(&.id).sort.should eq(["ab", "ca"])

      objs, rels = store.neighborhood("a", depth: 2)
      rels.map(&.id).sort.should eq(["ab", "bc", "ca"])
    end

    # ---- match_chain ----

    it "matches single-node chains" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("o1", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("o2", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("o3", type: "note"))
      GraphStoreConformanceFixture.chain_ids(store.match_chain([nil] of String?, [] of {String, String}))
        .should eq([{["o1"], [] of String}, {["o2"], [] of String}, {["o3"], [] of String}])
      GraphStoreConformanceFixture.chain_ids(store.match_chain(["memo"], [] of {String, String}))
        .should eq([{["o1"], [] of String}, {["o2"], [] of String}])
    end

    it "matches one-hop chains in both directions with type filters" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("a", type: "memo"))
      store.put_object(GraphStoreConformanceFixture.obj("b", type: "note"))
      store.put_relation(GraphStoreConformanceFixture.rel("ab", "a", "b", type: "links"))

      GraphStoreConformanceFixture.chain_ids(store.match_chain([nil, nil] of String?, [{"links", "right"}]))
        .should eq([{["a", "b"], ["ab"]}])
      GraphStoreConformanceFixture.chain_ids(store.match_chain([nil, nil] of String?, [{"links", "left"}]))
        .should eq([{["b", "a"], ["ab"]}])
      GraphStoreConformanceFixture.chain_ids(store.match_chain(["memo", "note"], [{"links", "right"}]))
        .should eq([{["a", "b"], ["ab"]}])
      store.match_chain(["memo", "memo"], [{"links", "right"}]).should be_empty
      store.match_chain([nil, nil] of String?, [{"cites", "right"}]).should be_empty
    end

    it "matches multi-hop chains" do
      store = {{store_factory}}
      %w(a b c d).each { |oid| store.put_object(GraphStoreConformanceFixture.obj(oid)) }
      store.put_relation(GraphStoreConformanceFixture.rel("ab", "a", "b", type: "links"))
      store.put_relation(GraphStoreConformanceFixture.rel("bc", "b", "c", type: "links"))
      store.put_relation(GraphStoreConformanceFixture.rel("cd", "c", "d", type: "cites"))

      GraphStoreConformanceFixture.chain_ids(
        store.match_chain([nil, nil, nil] of String?, [{"links", "right"}, {"links", "right"}])
      ).should eq([{["a", "b", "c"], ["ab", "bc"]}])
      GraphStoreConformanceFixture.chain_ids(
        store.match_chain([nil, nil, nil] of String?, [{"links", "right"}, {"cites", "right"}])
      ).should eq([{["b", "c", "d"], ["bc", "cd"]}])
    end

    it "matches chains homomorphically including self-loops" do
      store = {{store_factory}}
      store.put_object(GraphStoreConformanceFixture.obj("a"))
      store.put_relation(GraphStoreConformanceFixture.rel("r", "a", "a", type: "links"))

      GraphStoreConformanceFixture.chain_ids(
        store.match_chain([nil, nil, nil] of String?, [{"links", "right"}, {"links", "right"}])
      ).should eq([{["a", "a", "a"], ["r", "r"]}])
    end

    it "matches branching chains and cycles" do
      store = {{store_factory}}
      %w(a b c).each { |oid| store.put_object(GraphStoreConformanceFixture.obj(oid)) }
      store.put_relation(GraphStoreConformanceFixture.rel("ab", "a", "b", type: "links"))
      store.put_relation(GraphStoreConformanceFixture.rel("ac", "a", "c", type: "links"))
      store.put_relation(GraphStoreConformanceFixture.rel("bc", "b", "c", type: "links"))
      store.put_relation(GraphStoreConformanceFixture.rel("ca", "c", "a", type: "links"))

      GraphStoreConformanceFixture.chain_ids(store.match_chain([nil, nil] of String?, [{"links", "right"}]))
        .should eq([{["a", "b"], ["ab"]}, {["a", "c"], ["ac"]}, {["b", "c"], ["bc"]}, {["c", "a"], ["ca"]}])
      GraphStoreConformanceFixture.chain_ids(
        store.match_chain([nil, nil, nil] of String?, [{"links", "right"}, {"links", "right"}])
      ).should eq([
        {["a", "b", "c"], ["ab", "bc"]},
        {["a", "c", "a"], ["ac", "ca"]},
        {["b", "c", "a"], ["bc", "ca"]},
        {["c", "a", "b"], ["ca", "ab"]},
        {["c", "a", "c"], ["ca", "ac"]},
      ])
    end
  end
end
