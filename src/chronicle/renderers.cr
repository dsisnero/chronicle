require "json"

module Chronicle
  # Shared CLI renderers (upstream cli/renderers.py): resolve a memo's company
  # name for prose and render one memo object in the quickstart/operator
  # format. Chronicle's core is Sans-IO, so the renderers return lines
  # (`Array(String)`); the CLI / caller writes them. The line format matches
  # upstream `print_memo_section`.
  module Renderers
    extend self

    MEMO_RULE_WIDTH = 76

    # Resolve a memo's `company_id` to a human name for CLI prose (upstream
    # `company_name_for_memo`). "<unknown>" when the memo carries no company
    # id; the raw id when the company object is missing or has no name.
    def memo_company_name(graph : GraphProjection, memo : GraphObject) : String
      data = JSON.parse(memo.data).as_h?
      cid = data.try(&.["company_id"]?.try(&.as_s))
      return "<unknown>" if cid.nil?

      company = graph.get_object(cid)
      return cid if company.nil?

      company_data = JSON.parse(company.data).as_h?
      company_data.try(&.["name"]?.try(&.as_s)) || cid
    end

    # Render one memo object using the quickstart/operator format (upstream
    # `print_memo_section`). Returns the lines; the caller writes them.
    def memo_section_lines(graph : GraphProjection, memo : GraphObject) : Array(String)
      lines = [] of String
      rule = "-" * MEMO_RULE_WIDTH
      lines << rule
      lines << " Memo: #{memo_company_name(graph, memo)}"
      lines << rule
      lines << ""

      data = JSON.parse(memo.data).as_h?
      lines.concat(summary_section_lines(data))
      lines.concat(key_claims_section_lines(data))
      lines.concat(contradictions_section_lines(data))
      lines.concat(risks_section_lines(data))
      lines
    end

    private def summary_section_lines(data : Hash(String, JSON::Any)?) : Array(String)
      lines = [] of String
      summary = data.try(&.["summary"]?.try(&.as_s?)) || ""
      return lines if summary.empty?

      lines << "Summary:"
      wrap_indented(summary, indent: "  ", width: 74).each { |line| lines << line }
      lines << ""
      lines
    end

    private def key_claims_section_lines(data : Hash(String, JSON::Any)?) : Array(String)
      lines = [] of String
      claims = data.try(&.["key_claims"]?.try(&.as_a?)) || [] of JSON::Any
      return lines if claims.empty?

      lines << "Key claims:"
      claims.each do |claim|
        claim_data = claim.as_h?
        text = claim_data.try(&.["text"]?.try(&.as_s?)) || claim_data.try(&.["claim"]?.try(&.as_s?)) || ""
        evidence_ids = claim_data.try(&.["evidence_ids"]?.try(&.as_a?)) || [] of JSON::Any
        ev_ids = evidence_ids.compact_map(&.as_s?)
        ev_clause = ev_ids.empty? ? "" : " (evidence: #{ev_ids.join(", ")})"
        lines << "  - #{text}#{ev_clause}"
      end
      lines << ""
      lines
    end

    private def contradictions_section_lines(data : Hash(String, JSON::Any)?) : Array(String)
      lines = [] of String
      contradictions = data.try(&.["open_contradictions"]?.try(&.as_a?)) || [] of JSON::Any
      note = data.try(&.["contradictions_note"]?.try(&.as_s?))
      lines << "Open contradictions:"
      if contradictions.empty?
        if note && !note.empty?
          lines << "  (#{note})"
        else
          lines << "  (none surfaced for this company)"
        end
      else
        contradictions.each { |contradiction| lines << "  - #{contradiction.to_json}" }
      end
      lines << ""
      lines
    end

    private def risks_section_lines(data : Hash(String, JSON::Any)?) : Array(String)
      lines = [] of String
      risks = data.try(&.["risks"]?.try(&.as_a?)) || [] of JSON::Any
      lines << "Risks:"
      if risks.empty?
        lines << "  (none identified)"
      else
        risks.each do |risk|
          risk_data = risk.as_h?
          title = risk_data.try(&.["title"]?.try(&.as_s?)) || ""
          severity = risk_data.try(&.["severity"]?.try(&.as_s?)) || ""
          related = risk_data.try(&.["related_claim_ids"]?.try(&.as_a?)) || [] of JSON::Any
          rel_ids = related.compact_map(&.as_s?)
          sev_clause = severity.empty? ? "" : "; severity: #{severity}"
          rel_clause = if !rel_ids.empty?
                         " (related claims: #{rel_ids.join(", ")}#{sev_clause})"
                       elsif !severity.empty?
                         " (#{sev_clause.lstrip("; ")})"
                       else
                         ""
                       end
          lines << "  - #{title}#{rel_clause}"
        end
      end
      lines << ""
      lines
    end

    # Wrap prose to a width with a leading indent (upstream `_wrap_indented`).
    private def wrap_indented(text : String, *, indent : String, width : Int32) : Array(String)
      out = [] of String
      current = indent
      text.split.each do |word|
        if current.size + word.size + 1 > width && !current.strip.empty?
          out << current.rstrip
          current = indent + word
        else
          current = current.strip.empty? ? indent + word : current + " " + word
        end
      end
      out << current.rstrip unless current.strip.empty?
      out
    end
  end
end
