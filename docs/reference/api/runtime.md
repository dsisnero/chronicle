# Runtime

The runtime loop. `Chronicle::Runtime(M)` is generic over the Crig
model `M` and is constructed with a `Chronicle::LogAgent(M)` plus a
store. It drives goal runs to completion and persists state through the
attached `EventStore`.

For the conceptual model see
[`docs/architecture.md`](../../architecture.md) and
[`plans/channel_protocol.md`](../../../plans/channel_protocol.md).

```crystal
require "chronicle"
require "crig"

store = Chronicle::MemoryEventStore.new
graph = Chronicle::GraphProjection.empty.attach_store(store)
agent = Crig::Agent(MyModel).new(model: MyModel.new, preamble: "")
log_agent = Chronicle::LogAgent(MyModel).new(agent, store: store, max_turns: 1)
worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(MyModel).new(model))

runtime = Chronicle::Runtime(MyModel).new(
  store: store,
  log_agent: log_agent,
  graph: graph,
  model_effect_worker: worker,
  run_id: "run_1",
)
```

## `Chronicle::Runtime(M)`

### Construction / loading

| Method | Signature |
| --- | --- |
| `.new` | `(store : EventStore, log_agent : LogAgent(M), policy : Routing::Policy? = nil, budget : Budget = Budget.new(max_events: 1000), available_targets : Array(Routing::Target) = [] of Routing::Target, run_id : String = "default", model_effect_worker : ModelEffectWorker? = nil, llm_cache : LLMCache? = nil, strict_expected_hashes : Array(String)? = nil, tools : Array(Tool) = [] of Tool, tool_cache : ToolCache? = nil, graph : GraphProjection? = nil, tool_approval_policies : Array(Policy) = [] of Policy, metrics : Metrics = NoOpMetrics.new, trace_context_reads : Bool = false, sinks : Array(SinkConfig) = [] of SinkConfig, llm_retry_max_attempts : Int32 = 3, llm_retry_initial_delay_seconds : Float64 = 0.5, llm_retry_max_delay_seconds : Float64 = 8.0, embedding_provider : EmbeddingProvider? = nil, embedding_cache : EmbeddingCache? = nil, replay_embedding_cache : Bool = false, strict_expected_embedding_hashes : Array(String)? = nil, native_structured_output : Bool = false, native_capability : Proc(String, Bool)? = nil)` |
| `.load` | `(path : String, run_id : String, agent : Crig::Agent(M), *, budget, max_turns, llm_retry_*, embedding_provider, replay_embedding_cache) -> Runtime(M)` |

### Run modes

| Method | Signature |
| --- | --- |
| `#run` | `(prompt : String, caused_by : String? = nil, max_steps : Int32? = nil) -> String` |
| `#run_quantum` | `(prompt : String, steps : Int32, caused_by : String? = nil) -> String` |
| `#run_quantum` | `(*, max_queue_events : Int32 = 25, max_seconds : Float64 = 0.25) -> RunQuantumResult` |
| `#run_until_idle` | `(prompt : String, caused_by : String? = nil) -> String` |
| `#run_until_idle` | `-> Nil` |
| `#run_until` | `(predicate : Proc(GraphProjection, Bool)) -> Nil` |
| `#run_goal` | `(goal : String, *, actor : String = "user") -> Nil` |

```crystal
runtime.run_goal("Diligence: Northwind Robotics")
```

### Introspection

| Method | Signature |
| --- | --- |
| `#status` | `-> RuntimeStatus` |
| `#errors` | `-> Array(BehaviorFailure)` |
| `#export_trace` | `-> String` |
| `#trace` | `-> TraceFacade` |
| `#print_graph` | `-> String` |
| `#budget_remaining` | `-> Int64` |
| `#start_budget` | `(max_events : Int64) -> Runtime(M)` |
| `#save_state` | `(path : String? = nil) -> String` |

### Packs, tools, and graph

| Method | Signature |
| --- | --- |
| `#load_pack` | `(pack : Pack, settings : Hash(String, JSON::Any)? = nil, *, manifest_path : String? = nil) -> Bool` |
| `#disable_pack` | `(name : String) -> Bool` |
| `#pack_settings` | `(pack_name : String) -> Hash(String, JSON::Any)?` |
| `#pack_policies` | `-> Array(Packs::PackPolicy)` |
| `#pack_pending_approvals` | `-> Array(Packs::PackPendingApproval)` |
| `#get_tool` | `(name : String) -> Tool?` |
| `#tool_names` | `-> Array(String)` |
| `#tool_requires_approval?` | `(tool_name : String) -> Bool` |
| `#get_behavior` | `(name : String) -> Packs::PackBehavior` |
| `#graph` | `-> GraphProjection?` |
| `#propose_object` | `(object_type : String, data : String, *, reason : String = "") -> String` |
| `#approve_pack` | `(approval_id : String, approved_by : String? = nil) -> GraphObject` |

### Fork, diff, promote

| Method | Signature |
| --- | --- |
| `#fork` | `(at_event : String, label : String? = nil, *, replay_llm_cache : Bool = false, replay_tool_cache : Bool = false, llm_retry_* : ... , embedding_provider : EmbeddingProvider? = nil, replay_embedding_cache : Bool = false) -> Runtime(M)` |
| `#diff` | `(other : Runtime(M)) -> Diff` |
| `#promote` | `(fork : Runtime(M), *, dry_run : Bool = false) -> PromotePlan \| PromoteResult` |

`fork` requires a SQLite-backed runtime. Cross-store fork is not
supported in v1; the CLI's `fork`/`diff` operate on encoded event-log
files instead.

### Frames, approvals, authority

| Method | Signature |
| --- | --- |
| `#push_frame` / `#pop_frame` | `(frame : Frame) -> Runtime(M)` / `-> Frame` |
| `#current_frame_id` | `-> String?` |
| `#events_in_frame` | `(frame_id : String) -> Array(Event)` |
| `#add_pending_approval` | `(request : ApprovalRequest) -> Nil` |
| `#pending_approvals` | `-> Array(ApprovalRequest)` |
| `#approve` | `(request_id : String) -> ApprovalResult` |
| `#authority_ceiling` | `-> String` |
| `#set_authority_ceiling` | `(ceiling : String, *, actor : String, reason : String) -> String` |
| `#evaluate_capability_authority` | `(*, capability, action_class, ...) -> AuthorityDecision` |
| `#dev_override` / `#dev_overrides` | `-> ...` / `-> Array(DevOverride)` |

### Embeddings

| Method | Signature |
| --- | --- |
| `#embed` | `(texts : Array(String), *, model : String? = nil) -> Array(Array(Float64))` |

## `Chronicle::RuntimeStatus`

Point-in-time, read-only snapshot produced by `Runtime#status`
(CONTRACT v0.8 #11). There is no `last_error` field — errors are events;
filter `recent_events` for `behavior.failed`.

| Field | Type |
| --- | --- |
| `run_id` | `String` |
| `state` | `RuntimeState` (`Idle \| Running \| Stopped \| Exhausted`) |
| `queue_depth` | `Int32` |
| `events_processed` | `Int64` |
| `budget` | `BudgetSnapshot` |
| `frame` | `FrameSnapshot?` |
| `registered_behaviors` | `Array(BehaviorInfo)` |
| `recent_events` | `Array(EventSummary)` |

`RuntimeStatus#to_h` produces the JSON shape matching upstream
`status_to_dict` field names.

Supporting value objects: `BudgetSnapshot`, `FrameSnapshot`,
`BehaviorInfo` (`kind` is `"function" | "relation" | "llm"`),
`EventSummary`, `BehaviorFailure` (the `Runtime#errors` row), and
`RunQuantumResult`.

## `Chronicle::Frame`

Mission context for a run: `id`, `goal`, `constraints`,
`success_criteria`, and `permissions`. `Chronicle::FrameStack` is the
LIFO stack the runtime pushes/pops (`push`, `pop`, `current`, `size`).

## `Chronicle::Budget`

Multi-dimensional hard limits. When any limit is hit the runtime stops
gracefully and emits `runtime.budget_exhausted`.

`Budget::KNOWN_LIMITS` is `max_events`, `max_behavior_calls`,
`max_llm_calls`, `max_tool_calls`, `max_patches`, `max_depth`,
`max_seconds`, `max_cost_usd`. Any omitted dimension is unlimited.

```crystal
budget = Chronicle::Budget.new(limits: {
  "max_llm_calls" => 10.0,
  "max_cost_usd"  => 2.5,
})
```

`Budget#remaining(*, check_wall_clock : Bool = true)`,
`#consume(key, amount = 1.0)`, `#exhausted_by`, `#mark_exhausted`,
`#add_cost`, `#cost_remaining`, `#snapshot`.

> Divergence: upstream accumulates cost as `Decimal`; Chronicle uses
> `Float64` and mirrors the serialized value as a `String`.

## `Chronicle::DevOverride`

One accepted `dev.override` receipt scoped to a run and gate
(CONTRACT v1.8 #13–#15): `event_id`, `run_id`, `actor`, `reason`,
`target_gate`, `scope`, `resulting_authority`. `DevOverrideValidation`
holds the pure validation (`validate_override_request`,
`gate_forbidden?`, `receipt_from_event`, `authority_allows?`).

## `Chronicle::IDGen`

Per-graph monotonic id generation. Objects share one counter prefixed by
type (`task#1`, `claim#2`); events/relations/patches/frames each have
their own `evt_`/`rel_`/`patch_`/`frame_` sequence.

| Method | Signature |
| --- | --- |
| `#object` | `(type : String) -> String` |
| `#event` / `#relation` / `#patch` / `#frame` | `-> String` |
| `#run` | `-> String` (26-char Crockford base32 ULID) |
| `#reseed_from_events` | `(events : Array(Event)) -> IDGen` |
| `#reseed_from_snapshot` | `(counters : Hash(String, Int32)) -> IDGen` |
| `#snapshot_counters` | `-> Hash(String, Int32)` |

## Clocks

Behaviors get time only through `Chronicle::Clock` so deterministic runs
can swap implementations and replay never depends on the machine clock.

- `Chronicle::WallClock` — real UTC (default).
- `Chronicle::FrozenClock` — always returns the same timestamp.
- `Chronicle::TickingClock` — advances by `step_seconds` per call.

## Logging + registry helpers

Upstream `configure_logging` / `get_registry` / `clear_registry` /
`register` do not have one-to-one Crystal globals. The Crystal
equivalents are:

- `Chronicle::Logging` — the Sans-IO structured-log formatting core
  (`format_line`, `runtime_log_extra`, `set_payload_redactor`). Actual
  I/O happens at the platform edge.
- `Chronicle::Registry` — registration-ordered behavior matching
  (`Registry.new(behaviors).match(event, graph)`).
- `Chronicle::Packs::Registry` — pack discovery/registration
  (`register`, `discover`, `clear_discovery_cache`, `load_by_name`).

> Divergence: there is no process-global behavior `register` helper;
> behaviors are registered per-runtime through pack loading. See
> [`plans/parity.md`](../../../plans/parity.md).
