require "../spec_helper"

# Graph write/emit surface specs. Ported from activegraph tests/test_graph.py
# (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).

describe Chronicle::GraphProjection do
  it "adds an object by emitting an object.created event" do
    g = Chronicle::GraphProjection.empty
    obj = g.add_object("task", %({"title":"x","status":"open"}))
    obj.id.should eq("task#1")
    obj.type.should eq("task")
    obj.version.should eq(1_i64)
    g.events.size.should eq(1)
    g.events[0].type.should eq("object.created")
    g.get_object("task#1").not_nil!.data.should eq(%({"title":"x","status":"open"}))
  end

  it "adds a relation by emitting a relation.created event" do
    g = Chronicle::GraphProjection.empty
    a = g.add_object("task", %({"title":"a"}))
    b = g.add_object("task", %({"title":"b"}))
    r = g.add_relation(a.id, b.id, "depends_on")
    r.id.should start_with("rel_")
    r.from_id.should eq(a.id)
    r.to_id.should eq(b.id)
    g.events.map(&.type).should eq(["object.created", "object.created", "relation.created"])
  end

  it "returns objects stamped with actor provenance" do
    g = Chronicle::GraphProjection.empty
    obj = g.add_object("task", %({"title":"x"}), actor: "planner")
    obj.provenance.created_by.should eq("planner")
    JSON.parse(g.events[0].payload)["actor"]?.should be_nil
  end

  it "removes an object and cascades its relations" do
    g = Chronicle::GraphProjection.empty
    a = g.add_object("task", %({}))
    b = g.add_object("task", %({}))
    g.add_relation(a.id, b.id, "depends_on")
    g.all_relations.size.should eq(1)

    g.remove_object(a.id)
    g.get_object(a.id).should be_nil
    g.all_relations.should be_empty
    g.events.last.type.should eq("object.removed")
  end

  it "removes a single relation without affecting others" do
    g = Chronicle::GraphProjection.empty
    a = g.add_object("task", %({}))
    b = g.add_object("task", %({}))
    c = g.add_object("task", %({}))
    g.add_relation(a.id, b.id, "depends_on")
    g.add_relation(a.id, c.id, "depends_on")
    rel_to_remove = g.all_relations.find { |r| r.to_id == b.id }.not_nil!

    g.remove_relation(rel_to_remove.id)
    g.all_relations.map(&.to_id).should eq([c.id])
    g.get_object(a.id).should_not be_nil
  end

  it "no-ops removing an unknown object or relation" do
    g = Chronicle::GraphProjection.empty
    g.remove_object("nope")
    g.remove_relation("nope")
    g.events.should be_empty
  end

  it "refuses reserved fields injected via data" do
    g = Chronicle::GraphProjection.empty
    expect_raises(Chronicle::ReservedFieldError) do
      g.add_object("task", %({"title":"x","provenance":{"created_by":"evil"}}))
    end
    g.events.should be_empty
  end

  it "notifies listeners on emit" do
    g = Chronicle::GraphProjection.empty
    seen = [] of String
    g.add_listener(->(event : Chronicle::Event) { seen << event.type })
    g.add_object("task", %({}))
    seen.should eq(["object.created"])
    g.remove_object("task#1")
    seen.should eq(["object.created", "object.removed"])
  end

  it "removes a listener" do
    g = Chronicle::GraphProjection.empty
    seen = [] of String
    listener = ->(event : Chronicle::Event) { seen << event.type }
    g.add_listener(listener)
    g.remove_listener(listener).should be_true
    g.add_object("task", %({}))
    seen.should be_empty
  end

  it "appends emitted events to an attached store" do
    g = Chronicle::GraphProjection.empty
    store = Chronicle::MemoryEventStore.new
    g.attach_store(store)
    g.add_object("task", %({"title":"x"}))
    store.count.should eq(1)
    store.get_event(g.events[0].id).should_not be_nil
  end

  it "exposes applied events" do
    g = Chronicle::GraphProjection.empty
    g.add_object("task", %({}))
    g.add_object("task", %({}))
    g.events.size.should eq(2)
    g.events[0].type.should eq("object.created")
  end

  it "serializes objects and relations via JSON::Serializable" do
    g = Chronicle::GraphProjection.empty
    obj = g.add_object("task", %({"title":"x"}))
    d = JSON.parse(obj.to_json).as_h
    d["id"].as_s.should eq("task#1")
    d["type"].as_s.should eq("task")
    d["version"].as_i.should eq(1)
    d["data"].as_h["title"].as_s.should eq("x")
    d["provenance"].as_h["created_by"].as_s.should eq("system")

    a = g.add_object("task", %({}))
    b = g.add_object("task", %({}))
    rel = g.add_relation(a.id, b.id, "depends_on")
    rd = JSON.parse(rel.to_json).as_h
    rd["from_id"].as_s.should eq(a.id)
    rd["to_id"].as_s.should eq(b.id)
    rd["type"].as_s.should eq("depends_on")
  end
end
