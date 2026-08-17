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

  # The narrow surface a tool function body sees (upstream tools/context.py,
  # CONTRACT v0.7 #5): the triggering behavior + event id, the active frame,
  # an opaque `idempotency_key` to forward to external APIs (the runtime never
  # uses it for dedupe — caching is the cache's job), the decorator's
  # `timeout_seconds` (advisory), and the `external_io_mode` (default "forbid";
  # runtime dispatch supplies "runtime_recorded"; an intentional replay bypass
  # must say "live_unrecorded"). No graph reference — tools that need graph
  # state close over it explicitly at registration (make_graph_query_tool).
  # Divergence: the per-tool logger is platform-edge (Crystal has no stdlib
  # logging context) and `timeout_seconds` defaults to 30.0 (the Crystal
  # @[Tool] decorator has no timeout field yet).
  struct ToolContext
    getter behavior_name : String
    getter event_id : String
    getter frame_id : String?
    getter idempotency_key : String
    getter timeout_seconds : Float64
    getter external_io_mode : ExternalIOMode

    def initialize(
      @behavior_name : String = "",
      @event_id : String = "",
      @frame_id : String? = nil,
      @idempotency_key : String = "",
      @timeout_seconds : Float64 = 30.0,
      @external_io_mode : ExternalIOMode = ExternalIOMode::Forbid,
    )
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
    @ctx_fn : Proc(String, ToolContext, String)?
    @input_validator : Proc(String, Nil)?

    def initialize(
      @name : String,
      @description : String = "",
      @deterministic : Bool = false,
      @pack_local : Bool = false,
      @export_globally : Bool = false,
      @mode_fn : Proc(String, ExternalIOMode, String)? = nil,
      @input_validator : Proc(String, Nil)? = nil,
      @ctx_fn : Proc(String, ToolContext, String)? = nil,
      &@fn : String -> String
    )
    end

    def call(args : String) : String
      @fn.call(args)
    end

    # Validate the args JSON against the tool's declared input schema. Raises
    # ToolError(reason="tool.invalid_input") on any parse/schema failure so the
    # runtime fails the behavior loud instead of invoking the tool with bad
    # input (upstream `_invoke_tool`'s input_schema.model_validate guard). No-op
    # when the tool declares no input schema.
    def validate_input!(args : String) : Nil
      validator = @input_validator
      return if validator.nil?
      validator.call(args)
    rescue ex : Exception
      raise ToolError.new(
        "tool.invalid_input",
        "tool #{name.inspect} received invalid input: #{ex.message}",
        {"tool" => JSON::Any.new(name), "validation_errors" => JSON::Any.new(ex.message.to_s)},
      )
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

    # Invoke with the runtime's ToolContext (upstream `_invoke_tool`'s
    # `tool_fn(args, ctx)`): ctx-aware bodies receive the full context; tools
    # with a mode gate (web_fetch) see the context's external_io_mode; plain
    # tools receive args only.
    def call(args : String, ctx : ToolContext) : String
      if ctx_fn = @ctx_fn
        ctx_fn.call(args, ctx)
      elsif mode_fn = @mode_fn
        mode_fn.call(args, ctx.external_io_mode)
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
        @mode_fn,
        @input_validator,
        @ctx_fn,
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
      raise ToolError.new("tool.unrecorded_external_io", "direct web_fetch is unrecorded; use runtime tool dispatch or set external_io_mode='live_unrecorded' explicitly")
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
        raise ToolError.new("tool.unrecorded_external_io", "direct web_fetch is unrecorded; use runtime tool dispatch or set external_io_mode='live_unrecorded' explicitly")
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
