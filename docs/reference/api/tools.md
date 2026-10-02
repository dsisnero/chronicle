# Tools

The `@[Tool]` annotation and tool primitives. For the conceptual model
and the LLM-tool-loop interaction see
[behaviors](behaviors.md); for tools inside a pack see
[packs](packs.md).

## Annotation + base

ActiveGraph uses the `@tool` decorator. Chronicle uses the
`Chronicle::Packs::Annotations::Tool` annotation, collected by
`DSL.pack`. A tool method may declare only `args` and an optional `ctx`
parameter; the macro raises for any other shape.

```crystal
@[Tool(name: "search", description: "Search documents", deterministic: true)]
def self.search(args : String) : String
  # args is a JSON string; return a JSON string
  %({"refs":[]})
end

@[Tool(input_schema: SearchInput)]
def self.search_typed(args : String, ctx : Chronicle::ToolContext) : String
  # ctx.external_io_mode gates external I/O
  %({"refs":[]})
end
```

| Annotation key | Type | Default |
| --- | --- | --- |
| `name` | `String` | method name |
| `description` | `String` | `""` |
| `deterministic` | `Bool` | `false` |
| `export_globally` | `Bool` | `false` |
| `input_schema` | type | `nil` (validated via `from_json`) |

### `Chronicle::Tool`

The runtime-invokable tool: metadata plus a callable body. The body runs
`fn(args_json) -> output_json`; the runtime owns invocation and the
`tool.requested` / `tool.responded` event pair.

| Method | Signature |
| --- | --- |
| `.new` | `(name, description = "", deterministic = false, pack_local = false, export_globally = false, mode_fn = nil, input_validator = nil, ctx_fn = nil, &fn : String -> String)` |
| `#call` | `(args : String) -> String` |
| `#call` | `(args : String, mode : ExternalIOMode) -> String` |
| `#call` | `(args : String, ctx : ToolContext) -> String` |
| `#validate_input!` | `(args : String) -> Nil` (raises `ToolError` `tool.invalid_input`) |
| `#to_definition` | `-> Hash(String, JSON::Any)` |
| `#with_pack_prefix` | `(pack_name : String, short_name : String) -> Tool` |

`Tool#deterministic?`, `#pack_local?`, `#export_globally?` are boolean
accessors.

### `Chronicle::ToolContext`

The narrow surface a tool body sees (CONTRACT v0.7 #5). There is no
graph reference; tools that need graph state close over it at
registration.

| Field | Type |
| --- | --- |
| `behavior_name` | `String` |
| `event_id` | `String` |
| `frame_id` | `String?` |
| `idempotency_key` | `String` |
| `timeout_seconds` | `Float64` (default `30.0`) |
| `external_io_mode` | `ExternalIOMode` (default `Forbid`) |

### `Chronicle::ExternalIOMode`

`Forbid` (default, fail closed) | `RuntimeRecorded` (runtime dispatch) |
`LiveUnrecorded` (explicit replay bypass for unrecorded external I/O).

### Reference tools

| Method | Signature |
| --- | --- |
| `Chronicle.make_graph_query_tool` | `(graph : GraphProjection) -> Tool` |
| `Chronicle.make_web_fetch_tool` | `(fetcher : Proc(String, WebFetchOutput)? = nil) -> Tool` |

`web_fetch` fails closed: it refuses to run unless the caller explicitly
allows `live_unrecorded` external I/O, before any network contact.

## Registry helpers

### `Chronicle::ToolRegistry`

Global `@tool`-style registry. Runtime construction snapshots it unless
an explicit tools list is passed; tests clear it for isolation.
`register(tool)`, `snapshot : Array(Tool)`, `clear`.

> Divergence: upstream `get_tool_registry` / `clear_tool_registry` are
> module-level functions. Chronicle exposes the equivalent as
> `ToolRegistry` class methods, and the runtime's own tool lookup is
> `Runtime#get_tool`. See [`plans/parity.md`](../../../plans/parity.md).
