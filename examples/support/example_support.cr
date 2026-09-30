require "../../src/chronicle"

# Shared helpers for the runnable examples. These examples are the Crystal
# ports of the upstream `vendor/activegraph/examples/*.py` demos. Upstream uses
# global decorator registration and Pydantic providers; the Crystal port uses
# the pack DSL (`load_pack`) and scripted Crig models, so every demo runs
# offline and deterministically with no API key or network access.
module ExampleSupport
  extend self

  # Deterministic Crig completion model: returns canned text responses in
  # order. The Crystal analogue of upstream's `_DemoScriptedProvider` /
  # `RecordedDiligenceProvider`.
  class ScriptedModel
    include Crig::Completion::CompletionModel

    getter calls : Int32 = 0
    @responses : Array(String)

    def initialize(@responses : Array(String))
    end

    def completion(request : Crig::Completion::Request::CompletionRequest)
      @calls += 1
      text = @responses.shift? || "{}"
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text(text)
        ),
        Crig::Completion::Usage.new(input_tokens: 5_i64, output_tokens: 5_i64),
        "raw",
        "msg_#{@calls}",
      )
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "ScriptedModel has no streaming mode"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end

  # One scripted provider response: a final text turn or a tool call.
  alias ScriptedTurn = Crig::Completion::CompletionResponse(String)

  def turn_text(text : String) : ScriptedTurn
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(text)
      ),
      Crig::Completion::Usage.new(input_tokens: 5_i64, output_tokens: 5_i64),
      "raw",
      "msg_text",
    )
  end

  def turn_tool(id : String, name : String, args : String) : ScriptedTurn
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.tool_call(id, name, JSON.parse(args))
      ),
      Crig::Completion::Usage.new(input_tokens: 5_i64, output_tokens: 5_i64),
      "raw",
      "msg_#{id}",
    )
  end

  # A scripted model that plays a fixed sequence of text/tool-call turns; used
  # by the tool-loop demo. Falls back to `{}` once the script is exhausted.
  class ScriptedTurnModel
    include Crig::Completion::CompletionModel

    getter calls : Int32 = 0
    @turns : Array(ScriptedTurn)

    def initialize(@turns : Array(ScriptedTurn))
    end

    def completion(request : Crig::Completion::Request::CompletionRequest)
      @calls += 1
      @turns.shift? || ExampleSupport.turn_text("{}")
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "ScriptedTurnModel has no streaming mode"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end

  # Build a scripted runtime over a (default in-memory) event store. Mirrors the
  # construction idiom used by the pack runtime specs. Generic over the model
  # so tool-loop demos can supply a `ScriptedTurnModel`.
  def build(
    model : M,
    *,
    store : Chronicle::EventStore = Chronicle::MemoryEventStore.new,
    run_id : String = "default",
    budget : Chronicle::Budget = Chronicle::Budget.new(max_events: 1000),
    tools : Array(Chronicle::Tool) = [] of Chronicle::Tool,
    llm_cache : Chronicle::LLMCache? = nil,
    tool_cache : Chronicle::ToolCache? = nil,
    metrics : Chronicle::Metrics = Chronicle::NoOpMetrics.new,
  ) : {Chronicle::EventStore, Chronicle::GraphProjection, Chronicle::Runtime(M)} forall M
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(M).new(model: model, preamble: "")
    log_agent = Chronicle::LogAgent(M).new(agent, store: store, max_turns: 1)
    worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(M).new(model))
    runtime = Chronicle::Runtime(M).new(
      store: store,
      log_agent: log_agent,
      graph: graph,
      run_id: run_id,
      budget: budget,
      tools: tools,
      llm_cache: llm_cache,
      tool_cache: tool_cache,
      metrics: metrics,
      model_effect_worker: worker,
    )
    {store, graph, runtime}
  end

  # Emit a custom event type from inside a behavior. Mirrors upstream
  # `graph.emit("task.completed", {...})`; the projection stamps the id and the
  # single monotonic sequence, so the merged log stays codec-valid.
  def emit(
    graph : Chronicle::GraphProjection,
    type : String,
    payload : String,
    *,
    actor : String = "system",
    caused_by : String? = nil,
  ) : Chronicle::Event
    graph.emit(type, payload, actor: actor, caused_by: caused_by)
  end

  # The canonical CONTRACT #18 trace lines for a runtime's log.
  def print_trace(runtime : Chronicle::Runtime(M)) : Nil forall M
    runtime.trace.lines.each { |line| puts line }
  end
end
