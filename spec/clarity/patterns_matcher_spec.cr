require "../spec_helper"

# Cypher subset matcher specs. Ported from activegraph
# tests/test_pattern_matcher.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
# Uses a bare GraphProjection instead of the full runtime — the matcher is pure
# over (event, graph).

module PatternsMatcherSpecHelper
  extend self

  def obj_event(seq : UInt64, id : String, type : String, data : String) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","data":#{data}}),
    )
  end

  def rel_event(seq : UInt64, id : String, type : String, from : String, to : String) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "relation.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","from_id":"#{from}","to_id":"#{to}"}),
    )
  end

  def graph_with_two_claims_one_contradicts : Clarity::GraphProjection
    seq = 1_u64
    events = [] of Clarity::Event
    a = obj_event(seq, "obj_a", "claim", %({"text":"A","confidence":0.9,"status":"open"})); seq += 1
    b = obj_event(seq, "obj_b", "claim", %({"text":"B","confidence":0.8,"status":"open"})); seq += 1
    c = obj_event(seq, "obj_c", "claim", %({"text":"C","confidence":0.3,"status":"open"})); seq += 1
    r1 = rel_event(seq, "rel_1", "contradicts", "obj_a", "obj_b"); seq += 1
    r2 = rel_event(seq, "rel_2", "supports", "obj_a", "obj_c"); seq += 1
    [a, b, c, r1, r2].reduce(Clarity::GraphProjection.empty) { |g, e| g.apply(e) }
  end
end

describe Clarity::PatternMatcher do
  it "matches a single node by type" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim)").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(3)
    matches.all? { |m| m.bindings.has_key?("c") }.should be_true
  end

  it "matches node property equality" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim {confidence: 0.9})").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
  end

  it "matches a relationship by type" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(a:claim)-[:contradicts]->(b:claim)").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
    matches[0]["a"].should_not eq(matches[0]["b"])
  end

  it "binds a relationship variable" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(a:claim)-[r:contradicts]->(b:claim)").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
    matches[0].bindings.has_key?("r").should be_true
    matches[0]["r"].should start_with("rel_")
  end

  it "matches a directed left relationship" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(b:claim)<-[:contradicts]-(a:claim)").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
  end

  it "returns no match when no relationship exists" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(a:claim)-[:cites]->(b:claim)").compile
    matcher.matches(nil, g).should be_empty
  end

  it "matches a multi-hop chain" do
    seq = 1_u64
    events = [] of Clarity::Event
    a = PatternsMatcherSpecHelper.obj_event(seq, "obj_a", "claim", "{}"); seq += 1
    b = PatternsMatcherSpecHelper.obj_event(seq, "obj_b", "source", "{}"); seq += 1
    c = PatternsMatcherSpecHelper.obj_event(seq, "obj_c", "doc", "{}"); seq += 1
    r1 = PatternsMatcherSpecHelper.rel_event(seq, "rel_1", "cites", "obj_a", "obj_b"); seq += 1
    r2 = PatternsMatcherSpecHelper.rel_event(seq, "rel_2", "in", "obj_b", "obj_c"); seq += 1
    g = [a, b, c, r1, r2].reduce(Clarity::GraphProjection.empty) { |graph, e| graph.apply(e) }

    matcher = Clarity.parse("(a:claim)-[:cites]->(b:source)-[:in]->(c:doc)").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
    matches[0]["a"].should eq("obj_a")
    matches[0]["b"].should eq("obj_b")
    matches[0]["c"].should eq("obj_c")
  end

  it "filters matches with a WHERE comparison" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim) WHERE c.confidence > 0.5").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(2)
  end

  it "filters matches with WHERE AND" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim) WHERE c.confidence > 0.7 AND c.status = \"open\"").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(2)
  end

  it "inverts matches with WHERE NOT" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim) WHERE NOT c.confidence > 0.5").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
  end

  it "excludes subpatterns matched by NOT EXISTS" do
    seq = 1_u64
    events = [] of Clarity::Event
    a = PatternsMatcherSpecHelper.obj_event(seq, "obj_a", "claim", %({"text":"A"})); seq += 1
    b = PatternsMatcherSpecHelper.obj_event(seq, "obj_b", "claim", %({"text":"B"})); seq += 1
    x = PatternsMatcherSpecHelper.obj_event(seq, "obj_x", "claim", %({"text":"X"})); seq += 1
    r1 = PatternsMatcherSpecHelper.rel_event(seq, "rel_1", "contradicts", "obj_x", "obj_a"); seq += 1
    g = [a, b, x, r1].reduce(Clarity::GraphProjection.empty) { |graph, e| graph.apply(e) }

    matcher = Clarity.parse(
      "(c:claim) WHERE NOT EXISTS { (x:claim)-[:contradicts]->(c) }"
    ).compile
    matches = matcher.matches(nil, g)
    matches.map { |m| m["c"] }.sort.should eq(["obj_b", "obj_x"])
  end

  it "matches the two-high-confidence-claims-and-contradiction pattern" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse(
      "(c1:claim)-[r:contradicts]->(c2:claim) " \
      "WHERE c1.confidence > 0.7 AND c2.confidence > 0.7"
    ).compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
  end

  it "returns an empty list when no matches exist" do
    seq = 1_u64
    ev = PatternsMatcherSpecHelper.obj_event(seq, "obj_a", "claim", %({"confidence":0.1}))
    g = Clarity::GraphProjection.empty.apply(ev)
    matcher = Clarity.parse("(c:claim) WHERE c.confidence > 0.99").compile
    matcher.matches(nil, g).should be_empty
  end

  it "resolves a bare var path to the object id" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim) WHERE c = \"obj_a\"").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(1)
    matches[0]["c"].should eq("obj_a")
  end

  it "resolves object field access via c.type" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c) WHERE c.type = \"claim\"").compile
    matches = matcher.matches(nil, g)
    matches.size.should eq(3)
  end

  it "returns no match when ordered comparison operands are nil" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim) WHERE c.confidence > c.missing").compile
    matcher.matches(nil, g).should be_empty
  end

  it "raises on ordered comparison of incomparable types" do
    g = PatternsMatcherSpecHelper.graph_with_two_claims_one_contradicts
    matcher = Clarity.parse("(c:claim) WHERE c.confidence > c.status").compile
    expect_raises(Clarity::PatternTypeError) do
      matcher.matches(nil, g)
    end
  end
end
