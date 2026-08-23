require "../spec_helper"

# Cypher subset parser specs. Ported from activegraph
# tests/test_pattern_parser.py (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).
# Every supported construct + every explicitly-refused construct.

describe Chronicle do
  describe "parse" do
    # ---------- happy path: every supported construct ----------

    it "parses a single node with no type" do
      p = Chronicle.parse("(a)")
      p.match.nodes.size.should eq(1)
      p.match.nodes[0].var.should eq("a")
      p.match.nodes[0].type.should be_nil
      p.where.should be_nil
    end

    it "parses a node with a type" do
      p = Chronicle.parse("(a:claim)")
      p.match.nodes[0].type.should eq("claim")
    end

    it "parses a node with properties" do
      p = Chronicle.parse("(a:claim {confidence: 0.9, status: \"open\"})")
      props = p.match.nodes[0].properties
      props["confidence"].raw.should eq(0.9_f64)
      props["status"].raw.should eq("open")
    end

    it "parses an anonymous node" do
      p = Chronicle.parse("(:claim)")
      p.match.nodes[0].var.should be_nil
      p.match.nodes[0].type.should eq("claim")
    end

    it "parses a directed right relationship" do
      p = Chronicle.parse("(a)-[:supports]->(b)")
      p.match.rels.size.should eq(1)
      p.match.rels[0].type.should eq("supports")
      p.match.rels[0].direction.should eq("right")
      p.match.rels[0].var.should be_nil
    end

    it "parses a directed left relationship" do
      p = Chronicle.parse("(a)<-[:supports]-(b)")
      p.match.rels[0].direction.should eq("left")
    end

    it "binds a relationship variable" do
      p = Chronicle.parse("(a)-[r:supports]->(b)")
      p.match.rels[0].var.should eq("r")
    end

    it "parses a multi-hop chain" do
      p = Chronicle.parse("(a:claim)-[:supports]->(b:doc)-[:cites]->(c:source)")
      p.match.nodes.size.should eq(3)
      p.match.rels.size.should eq(2)
      p.match.nodes.map(&.type).should eq(["claim", "doc", "source"])
      p.match.rels.map(&.type).should eq(["supports", "cites"])
    end

    it "parses a simple WHERE comparison" do
      p = Chronicle.parse("(a:claim) WHERE a.confidence > 0.7")
      expr = p.where.as(Chronicle::Comparison)
      expr.op.should eq(">")
      expr.right_value.not_nil!.raw.should eq(0.7_f64)
    end

    it "parses a WHERE AND clause" do
      p = Chronicle.parse("(a:claim) WHERE a.confidence > 0.7 AND a.status = \"open\"")
      expr = p.where.as(Chronicle::AndExpr)
      expr.parts.size.should eq(2)
    end

    it "parses a WHERE NOT clause" do
      p = Chronicle.parse("(a:claim) WHERE NOT a.confidence < 0.3")
      p.where.should be_a(Chronicle::NotExpr)
    end

    it "parses a WHERE NOT EXISTS clause" do
      p = Chronicle.parse("(a:claim) WHERE NOT EXISTS { (a)-[:supersedes]->(b:claim) }")
      expr = p.where.as(Chronicle::NotExists)
      expr.sub_match.nodes[0].var.should eq("a")
      expr.sub_match.rels[0].type.should eq("supersedes")
    end

    it "parses a path vs path comparison" do
      p = Chronicle.parse("(a:c)-[:r]->(b:c) WHERE a.confidence > b.confidence")
      expr = p.where.as(Chronicle::Comparison)
      expr.right_path.should eq(["b", "confidence"])
    end

    it "parses a.data.field property paths" do
      p = Chronicle.parse("(a:claim) WHERE a.data.priority = 3")
      expr = p.where.as(Chronicle::Comparison)
      expr.left_path.should eq(["a", "data", "priority"])
    end

    it "parses all comparison operators" do
      {"=", "<", ">", "<=", ">=", "!=", "<>"}.each do |op|
        p = Chronicle.parse("(a:c) WHERE a.x #{op} 1")
        expr = p.where.as(Chronicle::Comparison)
        expr.op.should eq(op)
      end
    end

    it "parses double-quoted string literals" do
      p = Chronicle.parse("(a:c) WHERE a.x = \"hello\"")
      p.where.as(Chronicle::Comparison).right_value.not_nil!.raw.should eq("hello")
    end

    it "parses single-quoted string literals" do
      p = Chronicle.parse("(a:c) WHERE a.x = 'hello'")
      p.where.as(Chronicle::Comparison).right_value.not_nil!.raw.should eq("hello")
    end

    it "parses boolean literals" do
      p = Chronicle.parse("(a:c) WHERE a.x = TRUE")
      p.where.as(Chronicle::Comparison).right_value.not_nil!.raw.should eq(true)
      p = Chronicle.parse("(a:c) WHERE a.x = FALSE")
      p.where.as(Chronicle::Comparison).right_value.not_nil!.raw.should eq(false)
    end

    it "parses null literals" do
      p = Chronicle.parse("(a:c) WHERE a.x = NULL")
      p.where.as(Chronicle::Comparison).right_value.not_nil!.raw.should be_nil
    end

    # ---------- failure cases: anything OUTSIDE the subset ----------

    it "rejects OR in WHERE" do
      expect_raises(Chronicle::UnsupportedPatternError, /OR is not supported/) do
        Chronicle.parse("(a:c) WHERE a.x > 0 OR a.x < -1")
      end
    end

    it "rejects RETURN" do
      expect_raises(Chronicle::UnsupportedPatternError, /RETURN/) do
        Chronicle.parse("(a:c) RETURN a")
      end
    end

    it "rejects OPTIONAL MATCH" do
      expect_raises(Chronicle::UnsupportedPatternError, /OPTIONAL/) do
        Chronicle.parse("OPTIONAL (a:c)")
      end
    end

    it "rejects WITH" do
      expect_raises(Chronicle::UnsupportedPatternError, /WITH/) do
        Chronicle.parse("(a:c) WITH a")
      end
    end

    it "rejects the MATCH keyword" do
      expect_raises(Chronicle::UnsupportedPatternError, /MATCH/) do
        Chronicle.parse("MATCH (a:c)")
      end
    end

    it "rejects variable-length paths" do
      expect_raises(Chronicle::UnsupportedPatternError, /variable-length/) do
        Chronicle.parse("(a:c)-[*]->(b:c)")
      end
    end

    it "rejects undirected relationships" do
      expect_raises(Chronicle::UnsupportedPatternError, /undirected/) do
        Chronicle.parse("(a:c)-[:r]-(b:c)")
      end
    end

    it "rejects relationships without a type" do
      expect_raises(Chronicle::UnsupportedPatternError, /type required/) do
        Chronicle.parse("(a)-[]->(b)")
      end
    end

    it "rejects CREATE" do
      expect_raises(Chronicle::UnsupportedPatternError, /CREATE/) do
        Chronicle.parse("CREATE (a:c)")
      end
    end

    it "rejects MERGE" do
      expect_raises(Chronicle::UnsupportedPatternError, /MERGE/) do
        Chronicle.parse("MERGE (a:c)")
      end
    end

    it "rejects node properties that are not literals" do
      expect_raises(Chronicle::UnsupportedPatternError) do
        Chronicle.parse("(a:c {x: y})")
      end
    end

    it "rejects trailing junk" do
      expect_raises(Chronicle::UnsupportedPatternError, /trailing/) do
        Chronicle.parse("(a:c) junk_here")
      end
    end

    it "rejects unmatched parens" do
      expect_raises(Chronicle::UnsupportedPatternError) do
        Chronicle.parse("(a:c")
      end
    end

    it "rejects unsupported characters" do
      expect_raises(Chronicle::UnsupportedPatternError, /unexpected character/) do
        Chronicle.parse("(a:c) WHERE a.x ?? 1")
      end
    end
  end
end
