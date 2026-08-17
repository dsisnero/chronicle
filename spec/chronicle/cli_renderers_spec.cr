require "../spec_helper"

# Shared CLI renderers (upstream cli/renderers.py): resolve a memo's company
# name for prose and render one memo object in the quickstart/operator format.
# Chronicle's core is Sans-IO, so the renderers return lines (Array(String));
# the CLI / caller writes them. The line format matches `print_memo_section`.

describe Chronicle::Renderers do
  it "resolves a memo's company id to a human name" do
    graph = Chronicle::GraphProjection.empty
    company = graph.add_object("company", %({"name":"Northwind Robotics"}))
    memo = graph.add_object("memo", %({"company_id":#{company.id.to_json},"summary":"s"}))

    Chronicle::Renderers.memo_company_name(graph, memo).should eq("Northwind Robotics")
  end

  it "falls back to the company id when the company is missing" do
    graph = Chronicle::GraphProjection.empty
    memo = graph.add_object("memo", %({"company_id":"company#9","summary":"s"}))
    Chronicle::Renderers.memo_company_name(graph, memo).should eq("company#9")
  end

  it "renders a memo section in the quickstart/operator format" do
    graph = Chronicle::GraphProjection.empty
    company = graph.add_object("company", %({"name":"Northwind Robotics"}))
    memo = graph.add_object("memo", JSON.build do |json|
      json.object do
        json.field "company_id", company.id
        json.field "summary", "Growth dispute flagged."
        json.field "key_claims", JSON.parse(%([{"text":"Revenue grew 18%","evidence_ids":["evt_1","evt_2"]},{"text":"Uncited claim","evidence_ids":[]}]))
        json.field "open_contradictions", JSON.parse(%([{"claim_a_id":"c1","claim_b_id":"c2"}]))
        json.field "risks", JSON.parse(%([{"title":"Growth dispute","severity":"high","related_claim_ids":["c1"]},{"title":"Competition","severity":"medium","related_claim_ids":[]}]))
      end
    end)

    lines = Chronicle::Renderers.memo_section_lines(graph, memo)
    lines.should eq([
      "-" * 76,
      " Memo: Northwind Robotics",
      "-" * 76,
      "",
      "Summary:",
      "  Growth dispute flagged.",
      "",
      "Key claims:",
      "  - Revenue grew 18% (evidence: evt_1, evt_2)",
      "  - Uncited claim",
      "",
      "Open contradictions:",
      "  - {\"claim_a_id\":\"c1\",\"claim_b_id\":\"c2\"}",
      "",
      "Risks:",
      "  - Growth dispute (related claims: c1; severity: high)",
      "  - Competition (severity: medium)",
      "",
    ])
  end

  it "renders the contradictions note when no contradictions were surfaced" do
    graph = Chronicle::GraphProjection.empty
    company = graph.add_object("company", %({"name":"X"}))
    memo = graph.add_object("memo", JSON.build do |json|
      json.object do
        json.field "company_id", company.id
        json.field "open_contradictions", JSON.parse(%([]))
        json.field "contradictions_note", "no contradictions found"
      end
    end)

    lines = Chronicle::Renderers.memo_section_lines(graph, memo)
    lines.should contain("Open contradictions:")
    lines.should contain("  (no contradictions found)")
  end
end
