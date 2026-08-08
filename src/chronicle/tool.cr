require "json"

# Tool abstraction and registry. Ported from activegraph
# activegraph/tools/base.py, tools/decorators.py, tools/graph_query.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
module Chronicle
  # The external-I/O permission mode for a tool invocation. Ported from
  # activegraph ToolContext.external_io_mode: forbid (default, fail closed),
  # runtime_recorded (runtime dispatch), or live_unrecorded (explicit replay
  # bypass for unrecorded external I/O).
  enum ExternalIOMode
    Forbid
    RuntimeRecorded
    LiveUnrecorded

    def to_s : String
      case self
      in .forbid?           then "forbid"
      in .runtime_recorded? then "runtime_recorded"
      in .live_unrecorded?  then "live_unrecorded"
      end
    end
  end

  # Input schema for web_fetch.
  struct WebFetchInput
    getter url : String
    getter timeout_seconds : Float64

    def initialize(@url : String, @timeout_seconds : Float64 = 10.0)
    end
  end

  # Output schema for web_fetch.
  struct WebFetchOutput
    getter text : String
    getter status : Int32
    getter final_url : String

    def initialize(@text : String, @status : Int32, @final_url : String)
    end
  end

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
    @mode_fn : Proc(String, ExternalIOMode, String)?

    def initialize(
      @name : String,
      @description : String = "",
      @deterministic : Bool = false,
      @pack_local : Bool = false,
      @export_globally : Bool = false,
      @mode_fn : Proc(String, ExternalIOMode, String)? = nil,
      &@fn : String -> String
    )
    end

    def call(args : String) : String
      @fn.call(args)
    end

    # Invoke with an explicit external-I/O permission mode. Tools that
    # perform external I/O gate their body on this (web_fetch fails closed).
    def call(args : String, mode : ExternalIOMode) : String
      if mode_fn = @mode_fn
        mode_fn.call(args, mode)
      else
        @fn.call(args)
      end
    end

    # A canonical (prefixed) copy stamped with pack ownership.
    def with_pack_prefix(pack_name : String, short_name : String) : Tool
      self.class.new(
        "#{pack_name}.#{short_name}",
        @description,
        @deterministic,
        @pack_local,
        @export_globally,
      ) { |args| call(args) }.with_mode_fn(@mode_fn)
    end

    protected def with_mode_fn(mode_fn : Proc(String, ExternalIOMode, String)?) : Tool
      @mode_fn = mode_fn
      self
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

  # Reference tool: web_fetch (CONTRACT v0.7 #16, v1.8 #7). Non-deterministic
  # external-IO tool that fails closed: it refuses to run unless the caller
  # explicitly allows `live_unrecorded` external I/O, before any network
  # contact. The body is injected so the platform edge supplies the actual
  # HTTP fetch; production defaults to a hard fail (no network in the core).
  def self.make_web_fetch_tool(fetcher : Proc(String, WebFetchOutput)? = nil) : Tool
    fn = fetcher || ->(_url : String) {
      raise ToolError.new("tool.unrecorded_external_io: direct web_fetch is unrecorded; use runtime tool dispatch or set external_io_mode='live_unrecorded' explicitly")
    }
    Tool.new(
      "web_fetch",
      "Fetch the body text of a URL via HTTP GET. Follows redirects. " \
      "Requires explicit live_unrecorded external-IO permission.",
      false,
    ) { |_args| "" }.with_mode_fn(->(args : String, mode : ExternalIOMode) {
      input = JSON.parse(args).as_h
      url = input["url"].as_s
      unless mode.live_unrecorded?
        raise ToolError.new("tool.unrecorded_external_io: direct web_fetch is unrecorded; use runtime tool dispatch or set external_io_mode='live_unrecorded' explicitly")
      end
      output = fn.call(url)
      JSON.build do |json|
        json.object do
          json.field "text", output.text
          json.field "status", output.status
          json.field "final_url", output.final_url
        end
      end
    })
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
