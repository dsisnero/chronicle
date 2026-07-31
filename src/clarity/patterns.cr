require "json"

# Cypher subset parser + matcher. Ported from activegraph
# activegraph/runtime/patterns.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
#
# A strict subset of Cypher. Anything outside the subset raises
# `UnsupportedPatternError` pointing at the offending token.
#
# Supported (the LOCKED subset):
#   * Node patterns:           (var:type {prop: value, ...})
#   * Relationship patterns:   (a)-[var:rel_type]->(b)
#                              (a)<-[var:rel_type]-(b)
#   * Multi-hop:               (a)-[:r1]->(b)-[:r2]->(c)
#   * WHERE clauses:           WHERE expr
#       - comparisons:         a.confidence > 0.7
#       - AND                  (NO OR)
#       - NOT                  NOT a.confidence > 0.5
#       - NOT EXISTS { ... }   negation over a sub-pattern
#   * Node `{prop: value}` is EQUALITY ONLY.
#   * Identifiers:             ASCII letters/digits/underscore, leading letter.
#
# Refused (raises UnsupportedPatternError):
#   RETURN, OPTIONAL MATCH, variable-length paths, aggregation, WITH,
#   subqueries beyond NOT EXISTS, OR in WHERE, UNION/UNWIND/CREATE/MERGE/
#   SET/DELETE/DETACH.
module Clarity
  DOCS_BASE_URL = "https://docs.activegraph.ai"

  # Base class for pattern parse/match failures rejected by the deterministic core.
  class PatternError < DomainError
  end

  # A WHERE ordered comparison (`<`, `>`, `<=`, `>=`) applied to two
  # non-nil values of incomparable JSON types. Analogous to Python's TypeError.
  class PatternTypeError < PatternError
  end

  # Pattern uses syntax outside the v0.7 Cypher subset. Construct via
  # `.refused_feature` or `.syntax_error` factories.
  class UnsupportedPatternError < PatternError
    getter at : String?

    def initialize(
      summary : String,
      what_failed : String,
      why : String,
      how_to_fix : String,
      at : String? = nil,
    )
      @at = at
      super(summary)
    end

    # A recognized Cypher feature that the subset deliberately refuses.
    def self.refused_feature(
      feature : String,
      workaround : String,
      at : String? = nil,
      why : String? = nil,
    ) : self
      new(
        "#{feature} is not supported in the v0.7 Cypher subset",
        "The pattern uses #{feature}. The v0.7 subset refuses this feature at " \
        "registration time — long before any match runs.",
        why || (
          "The pattern subset is deliberately small and exhaustively testable. " \
          "A fuzzy superset of Cypher would let patterns appear to match input " \
          "they did not actually match, which would break the audit trail that " \
          "pattern-driven behaviors preserve. See CONTRACT v0.7 #8 for the " \
          "locked subset."
        ),
        workaround,
        at,
      )
    end

    # Parser-level error: the pattern does not parse at all.
    def self.syntax_error(
      what : String,
      at : String? = nil,
      expected : String? = nil,
      got : String? = nil,
    ) : self
      summary = if !expected.nil? && !got.nil?
                  "pattern does not parse: expected #{expected}, got #{got}"
                else
                  "pattern does not parse: #{what}"
                end
      body_top = if !expected.nil? && !got.nil?
                   "While parsing the pattern, the parser expected #{expected} " \
                   "but found #{got}."
                 else
                   "While parsing the pattern: #{what}."
                 end
      body_top += "\n  at: #{at}" if at
      new(
        summary,
        body_top,
        "Behaviors register their pattern subscriptions at startup, so the " \
        "parser refuses ambiguous syntax now rather than risk matching a " \
        "pattern the developer did not actually write. An unparseable " \
        "pattern is a configuration bug; matching is the next concern.",
        "Fix the syntax. The supported subset is documented in CONTRACT v0.7 " \
        "#8 and at\n    #{DOCS_BASE_URL}/concepts/patterns\nIf the syntax " \
        "looks right, check for unbalanced brackets, a missing relationship " \
        "type, or a missing arrow direction.",
        at,
      )
    end
  end

  # Per-keyword recovery prose for refused features.
  KEYWORD_WORKAROUNDS = {
    "RETURN"   => "Pattern subscriptions do not return values. Bindings reach the behavior body via `ctx.matches` — read them there.",
    "OPTIONAL" => "OPTIONAL MATCH expresses 'match if present, else null.' The runtime does not have a null binding. Register a second behavior whose pattern is the optional sub-pattern.",
    "WITH"     => "WITH composes a pipeline of matches. The runtime evaluates each pattern as a flat match; pipelines are expressed as multiple behaviors chained through emitted events.",
    "MATCH"    => "Multiple MATCH clauses compose a pipeline. Flatten the pattern or register one behavior per clause and chain them through emitted events.",
    "UNWIND"   => "UNWIND iterates a collection. Iterate in the behavior body instead — `for row in ctx.matches: ...` — and express the source collection as a sub-pattern.",
    "UNION"    => "UNION takes the union of two queries. Register two behaviors, one per branch, and let both fire.",
    "CREATE"   => "Patterns observe the graph; they do not mutate it. Mutations go in the behavior body via `graph.add_object` / `graph.add_relation`.",
    "MERGE"    => "Same as CREATE — patterns do not mutate. Use `graph.add_object` (with idempotency handled by the behavior) in the body instead.",
    "SET"      => "Same as CREATE — patterns do not mutate. Use `graph.patch_object` in the behavior body.",
    "DELETE"   => "Same as CREATE — patterns do not mutate. Use `graph.remove_object` / `graph.remove_relation` in the behavior body.",
    "DETACH"   => "Same as DELETE — patterns do not mutate.",
    "REMOVE"   => "Same as DELETE — patterns do not mutate.",
    "FOREACH"  => "FOREACH iterates inside the pattern. Iterate in the behavior body instead.",
    "CALL"     => "CALL invokes a procedure. The runtime has no procedure registry; call your function from the behavior body.",
    "LIMIT"    => "LIMIT caps result count. Apply the cap in the behavior body by slicing `ctx.matches`.",
    "SKIP"     => "SKIP offsets results. Apply the offset in the behavior body.",
    "ORDER"    => "ORDER BY sorts results. Sort in the behavior body.",
  } of String => String

  KEYWORDS           = %w(WHERE AND OR NOT EXISTS TRUE FALSE NULL)
  FORBIDDEN_KEYWORDS = %w(RETURN OPTIONAL WITH MATCH UNWIND UNION CREATE MERGE SET DELETE DETACH REMOVE FOREACH CALL LIMIT SKIP ORDER)

  # ---------- AST ----------

  class NodePat
    getter var : String?
    getter type : String?
    getter properties : Hash(String, JSON::Any)

    def initialize(
      @var : String? = nil,
      @type : String? = nil,
      @properties = {} of String => JSON::Any,
    )
    end
  end

  class RelPat
    getter var : String?
    getter type : String
    # "right" = (a)-[]->(b); "left" = (a)<-[]-(b). Undirected not supported.
    getter direction : String

    def initialize(@type : String, @direction : String, @var : String? = nil)
    end
  end

  # Linear chain of nodes connected by relationships.
  class MatchClause
    getter nodes : Array(NodePat)
    getter rels : Array(RelPat)

    def initialize(
      @nodes : Array(NodePat) = [] of NodePat,
      @rels : Array(RelPat) = [] of RelPat,
    )
    end
  end

  # Either path-vs-literal or path-vs-path.
  class Comparison
    getter left_path : Array(String)
    getter op : String
    getter right_path : Array(String)?
    getter right_value : JSON::Any?

    def initialize(
      @left_path : Array(String),
      @op : String,
      @right_path : Array(String)? = nil,
      @right_value : JSON::Any? = nil,
    )
    end
  end

  class NotExpr
    getter inner : BoolExpr

    def initialize(@inner : BoolExpr)
    end
  end

  class NotExists
    getter sub_match : MatchClause

    def initialize(@sub_match : MatchClause)
    end
  end

  class AndExpr
    getter parts : Array(BoolExpr)

    def initialize(@parts : Array(BoolExpr) = [] of BoolExpr)
    end
  end

  alias BoolExpr = Comparison | NotExpr | NotExists | AndExpr

  # A parsed pattern plus its original source text.
  class Pattern
    getter match : MatchClause
    getter where : BoolExpr?
    getter source : String

    def initialize(
      @match : MatchClause,
      @where : BoolExpr? = nil,
      @source : String = "",
    )
    end

    def compile : PatternMatcher
      PatternMatcher.new(self)
    end
  end

  # ---------- Lexer ----------

  record Tok, kind : String, text : String, pos : Int32

  private module PatternLexer
    extend self

    def tokenize(s : String) : Array(Tok)
      tokens = [] of Tok
      pos = 0
      while pos < s.size
        ch = s[pos]
        if ch.ascii_whitespace?
          pos += 1
          next
        end
        matched = match_token(s, pos)
        if matched.nil?
          raise UnsupportedPatternError.syntax_error(
            what: "unexpected character at position #{pos}",
            at: slice_at(s, pos, 8),
          )
        end
        kind, text = matched
        if kind == "IDENT"
          upper = text.upcase
          if FORBIDDEN_KEYWORDS.includes?(upper)
            workaround = KEYWORD_WORKAROUNDS[upper]? || (
              "Remove the #{upper} keyword. The v0.7 subset refuses it; no " \
              "equivalent in-subset expression exists for this case."
            )
            raise UnsupportedPatternError.refused_feature(
              feature: "the #{upper} keyword",
              workaround: workaround,
              at: text,
            )
          end
          if KEYWORDS.includes?(upper)
            kind = "KW_#{upper}"
            text = upper
          end
        end
        tokens << Tok.new(kind: kind, text: text, pos: pos)
        pos += text.size
      end
      tokens << Tok.new(kind: "EOF", text: "", pos: pos)
      tokens
    end

    def unescape_string(inner : String) : String
      return inner unless inner.includes?('\\')
      String.build do |io|
        i = 0
        while i < inner.size
          ch = inner[i]
          if ch == '\\' && i + 1 < inner.size
            i = append_escape(io, inner, i, inner[i + 1])
          else
            io << ch
            i += 1
          end
        end
      end
    end

    private def append_escape(io : IO, inner : String, i : Int32, nxt : Char) : Int32
      case nxt
      when 'n'  then io << '\n'
      when 'r'  then io << '\r'
      when 't'  then io << '\t'
      when 'b'  then io << '\b'
      when 'f'  then io << '\f'
      when 'v'  then io << '\v'
      when 'a'  then io << '\a'
      when '\\' then io << '\\'
      when '"'  then io << '"'
      when '\'' then io << '\''
      when 'u'
        return append_unicode(io, inner, i)
      else
        io << '\\' << nxt
      end
      i + 2
    end

    private def append_unicode(io : IO, inner : String, i : Int32) : Int32
      hex = i + 2 < inner.size ? inner[i + 2, Math.min(4, inner.size - i - 2)] : ""
      if hex.size == 4 && hex.each_char.all? { |char| hex_digit?(char) }
        io << hex.to_u16(16).chr
        i + 6
      else
        io << "u"
        i + 2
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def match_token(s : String, pos : Int32) : {String, String}?
      ch = s[pos]
      case ch
      when '"', '\''
        text = scan_string(s, pos, ch)
        text.nil? ? nil : {"STRING", text}
      when '-'
        if pos + 1 < s.size && s[pos + 1] == '>'
          {"ARROW_R", "->"}
        elsif pos + 1 < s.size && s[pos + 1].ascii_number?
          scan_number(s, pos)
        else
          {"DASH", "-"}
        end
      when '<'
        if pos + 1 < s.size && s[pos + 1] == '-'
          {"ARROW_L", "<-"}
        elsif pos + 1 < s.size && s[pos + 1] == '='
          {"OP", "<="}
        elsif pos + 1 < s.size && s[pos + 1] == '>'
          {"OP", "<>"}
        else
          {"OP", "<"}
        end
      when '>'
        if pos + 1 < s.size && s[pos + 1] == '='
          {"OP", ">="}
        else
          {"OP", ">"}
        end
      when '!'
        if pos + 1 < s.size && s[pos + 1] == '='
          {"OP", "!="}
        else
          nil
        end
      when '='
        {"OP", "="}
      when '0'..'9'
        scan_number(s, pos)
      when '*'
        {"STAR", "*"}
      when '('
        {"LPAREN", "("}
      when ')'
        {"RPAREN", ")"}
      when '['
        {"LBRACK", "["}
      when ']'
        {"RBRACK", "]"}
      when '{'
        {"LBRACE", "{"}
      when '}'
        {"RBRACE", "}"}
      when ','
        {"COMMA", ","}
      when ':'
        {"COLON", ":"}
      when '.'
        {"DOT", "."}
      when .ascii_letter?, '_'
        scan_ident(s, pos)
      else
        nil
      end
    end

    private def scan_ident(s : String, pos : Int32) : {String, String}
      i = pos
      while i < s.size && (s[i].ascii_alphanumeric? || s[i] == '_')
        i += 1
      end
      {"IDENT", s[pos, i - pos]}
    end

    private def scan_number(s : String, pos : Int32) : {String, String}
      i = pos
      i += 1 if s[i] == '-'
      while i < s.size && s[i].ascii_number?
        i += 1
      end
      if i < s.size && s[i] == '.' && i + 1 < s.size && s[i + 1].ascii_number?
        i += 1
        while i < s.size && s[i].ascii_number?
          i += 1
        end
      end
      {"NUMBER", s[pos, i - pos]}
    end

    private def scan_string(s : String, pos : Int32, quote : Char) : String?
      i = pos + 1
      while i < s.size
        case s[i]
        when '\\'
          i += 2
        when quote
          return s[pos, i - pos + 1]
        else
          i += 1
        end
      end
      nil
    end

    private def slice_at(s : String, pos : Int32, n : Int32) : String
      return "" if pos >= s.size
      s[pos, Math.min(n, s.size - pos)]
    end

    private def hex_digit?(c : Char) : Bool
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    end
  end

  # ---------- Parser ----------

  private class PatternParser
    @tokens : Array(Tok)
    @source : String
    @i : Int32

    def initialize(@tokens : Array(Tok), @source : String)
      @i = 0
    end

    def peek(offset : Int32 = 0) : Tok
      @tokens[Math.min(@i + offset, @tokens.size - 1)]
    end

    def eat(kind : String, text : String? = nil) : Tok
      t = peek
      unless t.kind == kind && (text.nil? || t.text == text)
        expected = kind + (text ? " #{text.inspect}" : "")
        raise UnsupportedPatternError.syntax_error(
          what: "expected #{expected}, got #{t.kind} #{t.text.inspect}",
          expected: expected,
          got: "#{t.kind} #{t.text.inspect}",
          at: at_text(t),
        )
      end
      @i += 1
      t
    end

    def consume_if(kind : String, text : String? = nil) : Tok?
      t = peek
      if t.kind == kind && (text.nil? || t.text == text)
        @i += 1
        return t
      end
      nil
    end

    def parse_pattern : Pattern
      match_clause = parse_match
      where = consume_if("KW_WHERE") ? parse_bool_expr : nil
      t = peek
      unless t.kind == "EOF"
        raise UnsupportedPatternError.syntax_error(
          what: "unexpected trailing tokens after pattern: #{t.kind} #{t.text.inspect}",
          at: t.text,
        )
      end
      Pattern.new(match: match_clause, where: where, source: @source)
    end

    def parse_match : MatchClause
      first = parse_node
      nodes = [first]
      rels = [] of RelPat
      while peek.kind == "DASH" || peek.kind == "ARROW_L"
        rel = parse_rel
        nxt = parse_node
        rels << rel
        nodes << nxt
      end
      MatchClause.new(nodes: nodes, rels: rels)
    end

    def parse_node : NodePat
      eat("LPAREN")
      var = peek.kind == "IDENT" ? eat("IDENT").text : nil
      type = consume_if("COLON") ? eat("IDENT").text : nil
      props = {} of String => JSON::Any
      if consume_if("LBRACE")
        props = parse_props
        eat("RBRACE")
      end
      eat("RPAREN")
      NodePat.new(var: var, type: type, properties: props)
    end

    def parse_rel : RelPat
      t = peek
      if t.kind == "DASH"
        eat("DASH")
        rel_var, rel_type = parse_edge_brackets
        arrow = peek
        if arrow.kind == "ARROW_R"
          eat("ARROW_R")
          return RelPat.new(var: rel_var, type: rel_type, direction: "right")
        end
        if arrow.kind == "DASH"
          raise UnsupportedPatternError.refused_feature(
            feature: "undirected-relationship syntax",
            workaround: "Pick a direction. Use `(a)-[:rel]->(b)` for source→target " \
                        "or `(a)<-[:rel]-(b)` for target→source. The pattern matcher needs " \
                        "the direction so the audit trail knows which endpoint produced " \
                        "the binding.",
            at: "-",
          )
        end
        raise UnsupportedPatternError.syntax_error(
          what: "expected '->' after relationship, got #{arrow.kind} #{arrow.text.inspect}",
          expected: "'->'",
          got: "#{arrow.kind} #{arrow.text.inspect}",
          at: arrow.text,
        )
      end
      if t.kind == "ARROW_L"
        eat("ARROW_L")
        rel_var, rel_type = parse_edge_brackets
        eat("DASH")
        return RelPat.new(var: rel_var, type: rel_type, direction: "left")
      end
      raise UnsupportedPatternError.syntax_error(
        what: "expected relationship between nodes, got #{t.kind} #{t.text.inspect}",
        expected: "a relationship",
        got: "#{t.kind} #{t.text.inspect}",
        at: t.text,
      )
    end

    private def parse_edge_brackets : {String?, String}
      eat("LBRACK")
      if consume_if("STAR")
        raise UnsupportedPatternError.refused_feature(
          feature: "variable-length path syntax (-[*]-)",
          workaround: "Express the path as N separate one-hop patterns and " \
                      "register one behavior per length you care about. If the path " \
                      "length is unbounded, the matcher would have unbounded cost — " \
                      "that's the reason for the refusal, not just policy.",
          at: "*",
        )
      end
      var = peek.kind == "IDENT" ? eat("IDENT").text : nil
      unless consume_if("COLON")
        t = peek
        raise UnsupportedPatternError.syntax_error(
          what: "relationship type required (e.g. [:supports] or [r:supports])",
          at: t.text,
        )
      end
      type_tok = eat("IDENT")
      eat("RBRACK")
      {var, type_tok.text}
    end

    private def parse_props : Hash(String, JSON::Any)
      props = {} of String => JSON::Any
      return props if peek.kind == "RBRACE"
      loop do
        key = eat("IDENT").text
        eat("COLON")
        props[key] = parse_literal
        break unless consume_if("COMMA")
      end
      props
    end

    private def parse_bool_expr : BoolExpr
      parts = [parse_unary]
      while consume_if("KW_AND")
        parts << parse_unary
      end
      if consume_if("KW_OR")
        raise UnsupportedPatternError.refused_feature(
          feature: "OR",
          workaround: "Register two behaviors, one per branch of the " \
                      "disjunction. Both fire independently; if both branches are true " \
                      "for the same event, both behaviors fire (which is usually what " \
                      "you want — OR-then-dedup is not).\n\nExample:\n  Instead of: " \
                      "WHERE c.confidence > 0.7 OR c.severity = 'high'\n  Register: " \
                      "one behavior with WHERE c.confidence > 0.7\n  one behavior with " \
                      "WHERE c.severity = 'high'",
          why: "OR in WHERE clauses can produce match-set ambiguity at the " \
               "trace level: it's hard to tell, after the fact, which branch of " \
               "the OR actually triggered. Registering two behaviors keeps every " \
               "fire attributable to a specific pattern in the audit trail. See " \
               "CONTRACT v0.7 #8.",
          at: "OR",
        )
      end
      parts.size == 1 ? parts[0] : AndExpr.new(parts: parts)
    end

    private def parse_unary : BoolExpr
      if consume_if("KW_NOT")
        if consume_if("KW_EXISTS")
          eat("LBRACE")
          sub = parse_match
          eat("RBRACE")
          return NotExists.new(sub_match: sub)
        end
        return NotExpr.new(inner: parse_unary)
      end
      if consume_if("LPAREN")
        inner = parse_bool_expr
        eat("RPAREN")
        return inner
      end
      parse_comparison
    end

    private def parse_comparison : Comparison
      left = parse_path
      t = peek
      if t.kind != "OP"
        raise UnsupportedPatternError.syntax_error(
          what: "expected comparison operator, got #{t.kind} #{t.text.inspect}",
          expected: "a comparison operator (=, <>, <, <=, >, >=)",
          got: "#{t.kind} #{t.text.inspect}",
          at: t.text,
        )
      end
      op = eat("OP").text
      nxt = peek
      if {"NUMBER", "STRING", "KW_TRUE", "KW_FALSE", "KW_NULL"}.includes?(nxt.kind)
        value = parse_literal
        return Comparison.new(left_path: left, op: op, right_value: value)
      end
      if nxt.kind == "IDENT"
        right_path = parse_path
        return Comparison.new(left_path: left, op: op, right_path: right_path)
      end
      raise UnsupportedPatternError.syntax_error(
        what: "expected literal or path on rhs of comparison, got #{nxt.kind} #{nxt.text.inspect}",
        expected: "a literal (number, string, true/false/null) or a binding path (a.field)",
        got: "#{nxt.kind} #{nxt.text.inspect}",
        at: nxt.text,
      )
    end

    private def parse_path : Array(String)
      first = eat("IDENT").text
      parts = [first]
      while consume_if("DOT")
        parts << eat("IDENT").text
      end
      parts
    end

    private def parse_literal : JSON::Any
      t = peek
      case t.kind
      when "NUMBER"
        @i += 1
        text = t.text
        text.includes?('.') ? JSON::Any.new(text.to_f64) : JSON::Any.new(text.to_i64)
      when "STRING"
        @i += 1
        JSON::Any.new(PatternLexer.unescape_string(t.text[1, t.text.size - 2]))
      when "KW_TRUE"
        @i += 1
        JSON::Any.new(true)
      when "KW_FALSE"
        @i += 1
        JSON::Any.new(false)
      when "KW_NULL"
        @i += 1
        JSON::Any.new(nil)
      else
        raise UnsupportedPatternError.syntax_error(
          what: "expected literal, got #{t.kind} #{t.text.inspect}",
          expected: "a literal (number, string, true, false, null)",
          got: "#{t.kind} #{t.text.inspect}",
          at: t.text,
        )
      end
    end

    private def at_text(t : Tok) : String
      return t.text unless t.text.empty?
      return "" if t.pos >= @source.size
      @source[t.pos, Math.min(8, @source.size - t.pos)]
    end
  end

  # Public entry point. Raises UnsupportedPatternError on any parse failure.
  def self.parse(pattern : String) : Pattern
    tokens = PatternLexer.tokenize(pattern)
    PatternParser.new(tokens, pattern).parse_pattern
  end

  # ---------- Matcher ----------

  # A single pattern binding: variable name → object/relation id.
  struct Match
    getter bindings : Hash(String, String)

    def initialize(@bindings : Hash(String, String))
    end

    def [](key : String) : String
      bindings[key]
    end

    def get(key : String, default : String? = nil) : String?
      bindings[key]? || default
    end
  end

  # One structural match of a linear node→rel→node chain.
  struct ChainMatch
    getter objects : Array(GraphObject)
    getter relations : Array(GraphRelation)

    def initialize(@objects : Array(GraphObject), @relations : Array(GraphRelation))
    end
  end

  # Pre-compiled matcher. Apply to (event, graph) → list of Match.
  class PatternMatcher
    getter pattern : Pattern

    def initialize(@pattern : Pattern)
    end

    def matches(event : Event?, graph : GraphProjection) : Array(Match)
      enumerate_matches(pattern.match, graph)
    end

    private def enumerate_matches(match_clause : MatchClause, graph : GraphProjection) : Array(Match)
      return [] of Match if match_clause.nodes.empty?
      node_types = match_clause.nodes.map(&.type)
      rels = match_clause.rels.map { |rel| {rel.type, rel.direction} }
      matches = [] of Match
      graph.match_chain(node_types, rels).each do |chain|
        objs = chain.objects
        ok = true
        objs.each_with_index do |obj, idx|
          unless node_matches(obj, match_clause.nodes[idx])
            ok = false
            break
          end
        end
        next unless ok
        bindings = bind_chain(match_clause, objs, chain.relations)
        next if bindings.nil?
        where = pattern.where
        if where.nil? || eval_where(where, bindings, graph)
          matches << Match.new(bindings: bindings)
        end
      end
      matches
    end

    private def bind_chain(
      match_clause : MatchClause,
      objs : Array(GraphObject),
      rels : Array(GraphRelation),
    ) : Hash(String, String)?
      bindings = {} of String => String
      match_clause.nodes.zip(objs).each do |node_pat, obj|
        if var = node_pat.var
          if existing = bindings[var]?
            return nil if existing != obj.id
          end
          bindings[var] = obj.id
        end
      end
      match_clause.rels.zip(rels).each do |rel_pat, rel|
        if var = rel_pat.var
          if existing = bindings[var]?
            return nil if existing != rel.id
          end
          bindings[var] = rel.id
        end
      end
      bindings
    end

    private def node_matches(obj : GraphObject, node_pat : NodePat) : Bool
      return false if !node_pat.type.nil? && obj.type != node_pat.type
      return true if node_pat.properties.empty?
      data = JsonCompare.object_data_hash(obj.data)
      node_pat.properties.each do |k, v|
        val = data[k]?
        return false if val.nil?
        return false unless JsonCompare.json_equal?(val, v)
      end
      true
    end

    private def eval_where(
      expr : BoolExpr,
      bindings : Hash(String, String),
      graph : GraphProjection,
    ) : Bool
      case expr
      in Comparison
        left = resolve_path(expr.left_path, bindings, graph)
        right_path = expr.right_path
        right = if right_path.nil?
                  expr.right_value || JSON::Any.new(nil)
                else
                  resolve_path(right_path, bindings, graph)
                end
        fn = ops[expr.op]?
        if fn.nil?
          raise UnsupportedPatternError.new(
            "unknown comparison operator #{expr.op}",
            "The WHERE evaluator received a comparison with operator #{expr.op}, " \
            "but the operator table has no handler for it.",
            "The operator table is the source of truth for which comparison " \
            "operators the runtime accepts. If the parser produces an operator " \
            "the evaluator does not know about, the audit trail would silently " \
            "mis-evaluate the pattern — refuse instead.",
            "Fix the parser or the AST construction to only emit operators that " \
            "appear in the operator table.",
          )
        end
        fn.call(left, right)
      in NotExpr
        !eval_where(expr.inner, bindings, graph)
      in AndExpr
        expr.parts.all? { |part| eval_where(part, bindings, graph) }
      in NotExists
        sub_matcher = PatternMatcher.new(
          Pattern.new(match: expr.sub_match, where: nil, source: "<sub>")
        )
        sub_matcher.matches(nil, graph).each do |sub_match|
          consistent = true
          bindings.each do |key, value|
            if sub_match.bindings[key]? && sub_match.bindings[key] != value
              consistent = false
              break
            end
          end
          return false if consistent
        end
        true
      end
    end

    private def ops : Hash(String, Proc(JSON::Any, JSON::Any, Bool))
      {
        "="  => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.json_equal?(a, b) },
        "==" => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.json_equal?(a, b) },
        "!=" => ->(a : JSON::Any, b : JSON::Any) { !JsonCompare.json_equal?(a, b) },
        "<>" => ->(a : JSON::Any, b : JSON::Any) { !JsonCompare.json_equal?(a, b) },
        ">"  => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?(">", a, b) { |sign| sign > 0 } },
        "<"  => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?("<", a, b) { |sign| sign < 0 } },
        ">=" => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?(">=", a, b) { |sign| sign >= 0 } },
        "<=" => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?("<=", a, b) { |sign| sign <= 0 } },
      } of String => Proc(JSON::Any, JSON::Any, Bool)
    end

    private def resolve_path(
      path : Array(String),
      bindings : Hash(String, String),
      graph : GraphProjection,
    ) : JSON::Any
      return JSON::Any.new(nil) if path.empty?
      head = path[0]
      rest = path[1..]
      obj_id = bindings[head]?
      return JSON::Any.new(nil) if obj_id.nil?
      obj = graph.get_object(obj_id)
      return JSON::Any.new(nil) if obj.nil?
      return JSON::Any.new(obj.id) if rest.empty?
      cur, remaining = path_head(obj, rest)
      remaining.each do |component|
        return JSON::Any.new(nil) unless cur.raw.is_a?(Hash(String, JSON::Any))
        cur = cur[component]? || JSON::Any.new(nil)
      end
      cur
    end

    private def path_head(obj : GraphObject, rest : Array(String)) : {JSON::Any, Array(String)}
      data = JSON::Any.new(JsonCompare.object_data_hash(obj.data))
      case rest[0]
      when "id"      then {JSON::Any.new(obj.id), rest[1..]}
      when "type"    then {JSON::Any.new(obj.type), rest[1..]}
      when "version" then {JSON::Any.new(obj.version), rest[1..]}
      when "data"    then {data, rest[1..]}
      else                {data, rest}
      end
    end
  end
end
