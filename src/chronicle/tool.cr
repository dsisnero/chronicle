require "json"

# Tool abstraction and registry. Ported from activegraph
# activegraph/tools/base.py, tools/decorators.py, tools/graph_query.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
module Chronicle
  # A runtime-invokable tool: metadata plus a callable body. The body runs
  # `fn(args_json) -> output_json`; the runtime owns invocation and the
  # tool.requested / tool.responded event pair.
  class Tool
    getter name : String
    getter description : String
    getter? deterministic : Bool
    getter? pack_local : Bool
    getter? export_globally : Bool
    @fn : String -> String

    def initialize(
      @name : String,
      @description : String = "",
      @deterministic : Bool = false,
      @pack_local : Bool = false,
      @export_globally : Bool = false,
      &@fn : String -> String
    )
    end

    def call(args : String) : String
      @fn.call(args)
    end

    # A canonical (prefixed) copy stamped with pack ownership.
    def with_pack_prefix(pack_name : String, short_name : String) : Tool
      self.class.new(
        "#{pack_name}.#{short_name}",
        @description,
        @deterministic,
        @pack_local,
        @export_globally,
      ) { |args| call(args) }
    end

    # Provider-facing tool definition (sent in the `tools=` parameter).
    def to_definition : Hash(String, JSON::Any)
      {
        "name"        => JSON::Any.new(name),
        "description" => JSON::Any.new(description),
        "parameters"  => JSON::Any.new({"type" => JSON::Any.new("object")}),
      }
    end
  end

  # Global @tool-style registry. Runtime construction snapshots it unless an
  # explicit tools list is passed; tests clear it for isolation.
  class ToolRegistry
    @@tools = [] of Tool

    def self.register(tool : Tool) : Nil
      @@tools << tool
    end

    def self.snapshot : Array(Tool)
      @@tools.dup
    end

    def self.clear : Nil
      @@tools.clear
    end
  end

  # Reference tool: query the active graph by type + optional WHERE filter.
  # Bound to a projection at creation, so the tool primitive is general and
  # not just an external-API escape hatch.
  def self.make_graph_query_tool(graph : GraphProjection) : Tool
    Tool.new(
      "graph_query",
      "Query objects in the active graph by type and optional WHERE filter. " \
      "Returns object id, type, and data for matching objects.",
      true,
    ) { |args| run_graph_query(graph, args) }
  end

  def self.run_graph_query(graph : GraphProjection, args : String) : String
    input = JSON.parse(args).as_h
    object_type = input["object_type"]?.try(&.as_s)
    where = input["where"]?.try(&.as_h)
    limit = input["limit"]?.try(&.as_i) || 50
    results = graph.objects(type: object_type, where: where)
    truncated = results.size > limit
    refs = results.first(Math.min(limit, results.size)).map do |obj|
      JSON::Any.new({
        "id"   => JSON::Any.new(obj.id),
        "type" => JSON::Any.new(obj.type),
        "data" => JSON.parse(obj.data),
      })
    end
    JSON.build do |json|
      json.object do
        json.field "refs", refs
        json.field "truncated", truncated
      end
    end
  end
end
