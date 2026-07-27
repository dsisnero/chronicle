require "../spec_helper"

class MockModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Mock response")
      ),
      Crig::Completion::Usage.new,
      "raw",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

private alias T = Clarity::Routing::Target

private class RecordingModelExecutor < Clarity::ModelExecutor
  getter targets = [] of Clarity::Routing::Target?

  def initialize(@model : MockModel)
  end

  def completion(target : Clarity::Routing::Target?, request : Crig::Completion::Request::CompletionRequest) : Crig::Completion::CompletionResponse(String)
    @targets << target
    @model.completion(request)
  end
end

private class RetryableFailureExecutor < Clarity::ModelExecutor
  def completion(target : Clarity::Routing::Target?, request : Crig::Completion::Request::CompletionRequest) : Crig::Completion::CompletionResponse(String)
    raise Clarity::RetryableProviderError.new("temporary upstream failure")
  end
end

private class PrimaryFailsThenSucceedsExecutor < Clarity::ModelExecutor
  getter targets = [] of Clarity::Routing::Target?

  def initialize(@primary : Clarity::Routing::Target, @model : MockModel)
  end

  def completion(target : Clarity::Routing::Target?, request : Crig::Completion::Request::CompletionRequest) : Crig::Completion::CompletionResponse(String)
    @targets << target
    raise Clarity::RetryableProviderError.new("temporary primary failure") if target == @primary
    @model.completion(request)
  end
end

describe Clarity::Runtime do
  it "runs a prompt and records goal.created + effect events" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model, preamble: "You are helpful.")
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    response = runtime.run("Hello")

    store.count.should be >= 1
    events = store.iter_events
    events.any? { |e| e.type == "goal.created" }.should be_true
    response.should_not be_empty
  end

  it "records user and assistant chat turns as durable events" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model, preamble: "You are helpful.")
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    runtime.run("Hello")

    turns = store.iter_events.select { |event| event.type == "chat.message" }
    turns.map { |event| JSON.parse(event.payload).as_h["role"].as_s }.should eq(["user", "assistant"])
    turns.map { |event| JSON.parse(event.payload).as_h["content"].as_s }.should eq(["Hello", "Mock response"])
    turns.last.caused_by.should eq(turns.first.id)
  end

  it "applies budget limits" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)

    budget = Clarity::Runtime::Budget.new(max_events: 3)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent, budget: budget)

    runtime.run("Test")

    events = store.iter_events
    events.any? { |e| e.type == "budget.exhausted" }.should be_true
    # Events: goal.created + effect.requested + effect.responded + budget.exhausted
    store.count.should eq(4)
  end

  it "accepts an explicit target via routing" do
    store = Clarity::MemoryEventStore.new
    target = T.new("deepseek", "deepseek-v4-flash")
    policy = Clarity::Routing::Policy.new(
      default_target: target,
      default_fallbacks: [] of T,
    )
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)

    runtime = Clarity::Runtime(MockModel).new(
      store: store, log_agent: log_agent,
      policy: policy,
    )

    runtime.run("Route test")

    store.count.should be >= 1
  end

  it "records a route receipt before executing a routed prompt" do
    store = Clarity::MemoryEventStore.new
    target = T.new("deepseek", "deepseek-v4-flash")
    policy = Clarity::Routing::Policy.new(default_target: target, default_fallbacks: [] of T)
    model = MockModel.new
    agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent, policy: policy)

    runtime.run("Route this prompt")

    user_turn = store.iter_events.find! do |event|
      event.type == "chat.message" && JSON.parse(event.payload).as_h["role"].as_s == "user"
    end
    receipt = store.iter_events.find! { |event| event.type == "routing.decided" }
    payload = JSON.parse(receipt.payload).as_h

    receipt.actor.should eq("runtime")
    receipt.caused_by.should eq(user_turn.id)
    payload["provider"].as_s.should eq("deepseek")
    payload["model"].as_s.should eq("deepseek-v4-flash")
    payload["matched_rule"].as_s.should eq("default")
  end

  it "executes a routed prompt through the selected target" do
    store = Clarity::MemoryEventStore.new
    target = T.new("deepseek", "deepseek-v4-flash")
    policy = Clarity::Routing::Policy.new(default_target: target, default_fallbacks: [] of T)
    model = MockModel.new
    executor = RecordingModelExecutor.new(model)
    registry = Clarity::ProviderRegistry.new.register(target, executor)
    agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(
      store: store, log_agent: log_agent, policy: policy, model_executor: registry,
    )

    runtime.run("Use the selected target")

    executor.targets.should eq([target])
    request_event = store.iter_events.find! { |event| event.type == "llm.requested" }
    request_payload = JSON.parse(request_event.payload).as_h
    request_payload["provider"].as_s.should eq("deepseek")
    request_payload["model"].as_s.should eq("deepseek-v4-flash")
    events = store.iter_events
    events.index!(request_event).should be < events.index! { |event| event.type == "effect.responded" }
    response_event = events.find! { |event| event.type == "llm.responded" }
    response_event.caused_by.should eq(request_event.id)
    events.index!(request_event).should be < events.index!(response_event)
  end

  it "rejects a routed target that has no registered executor" do
    store = Clarity::MemoryEventStore.new
    target = T.new("deepseek", "deepseek-v4-flash")
    policy = Clarity::Routing::Policy.new(default_target: target, default_fallbacks: [] of T)
    model = MockModel.new
    agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(
      store: store, log_agent: log_agent, policy: policy, model_executor: Clarity::ProviderRegistry.new,
    )

    expect_raises(Clarity::ProviderNotAvailableError, "no executor registered for deepseek/deepseek-v4-flash") do
      runtime.run("Use an unregistered target")
    end

    store.iter_events.any? { |event| event.type == "routing.decided" }.should be_true
    request_event = store.iter_events.find! { |event| event.type == "llm.requested" }
    failed_event = store.iter_events.find! { |event| event.type == "llm.failed" }
    failed_event.caused_by.should eq(request_event.id)
  end

  it "marks a retryable provider failure in the durable receipt" do
    store = Clarity::MemoryEventStore.new
    target = T.new("deepseek", "deepseek-v4-flash")
    policy = Clarity::Routing::Policy.new(default_target: target, default_fallbacks: [] of T)
    model = MockModel.new
    agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(agent, store: store)
    registry = Clarity::ProviderRegistry.new.register(target, RetryableFailureExecutor.new)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent, policy: policy, model_executor: registry)

    expect_raises(Clarity::RetryableProviderError) { runtime.run("Retry this") }

    failed = store.iter_events.find! { |event| event.type == "llm.failed" }
    JSON.parse(failed.payload).as_h["retryable"].as_bool.should be_true
    exhausted = store.iter_events.find! { |event| event.type == "routing.fallback_exhausted" }
    exhausted.caused_by.should eq(failed.id)
  end

  it "retries only the next durable fallback after a retryable provider failure" do
    store = Clarity::MemoryEventStore.new
    primary = T.new("deepseek", "deepseek-v4-flash")
    fallback = T.new("ollama", "qwen2.5-coder", false)
    policy = Clarity::Routing::Policy.new(default_target: primary, default_fallbacks: [fallback])
    model = MockModel.new
    agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(agent, store: store)
    executor = PrimaryFailsThenSucceedsExecutor.new(primary, model)
    registry = Clarity::ProviderRegistry.new.register(primary, executor).register(fallback, executor)
    runtime = Clarity::Runtime(MockModel).new(
      store: store, log_agent: log_agent, policy: policy,
      available_targets: [primary, fallback], model_executor: registry,
    )

    runtime.run("Retry via fallback").should eq("Mock response")

    executor.targets.should eq([primary, fallback])
    fallback_event = store.iter_events.find! { |event| event.type == "routing.fallback_selected" }
    failed_event = store.iter_events.find! { |event| event.type == "llm.failed" }
    fallback_event.caused_by.should eq(failed_event.id)
    failed_payload = JSON.parse(failed_event.payload).as_h
    failed_payload["provider"].as_s.should eq("deepseek")
    failed_payload["model"].as_s.should eq("deepseek-v4-flash")
    payload = JSON.parse(fallback_event.payload).as_h
    payload["provider"].as_s.should eq("ollama")
    payload["model"].as_s.should eq("qwen2.5-coder")
    response = store.iter_events.select { |event| event.type == "llm.responded" }.last
    response_payload = JSON.parse(response.payload).as_h
    response_payload["provider"].as_s.should eq("ollama")
    response_payload["model"].as_s.should eq("qwen2.5-coder")
  end

  it "does not fallback after a non-retryable missing executor failure" do
    store = Clarity::MemoryEventStore.new
    primary = T.new("deepseek", "deepseek-v4-flash")
    fallback = T.new("ollama", "qwen2.5-coder", false)
    policy = Clarity::Routing::Policy.new(default_target: primary, default_fallbacks: [fallback])
    model = MockModel.new
    agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(agent, store: store)
    fallback_executor = RecordingModelExecutor.new(model)
    registry = Clarity::ProviderRegistry.new.register(fallback, fallback_executor)
    runtime = Clarity::Runtime(MockModel).new(
      store: store, log_agent: log_agent, policy: policy,
      available_targets: [primary, fallback], model_executor: registry,
    )

    expect_raises(Clarity::ProviderNotAvailableError) { runtime.run("Do not retry configuration errors") }

    store.iter_events.any? { |event| event.type == "routing.fallback_selected" }.should be_false
    fallback_executor.targets.should be_empty
  end

  it "loads from store and resumes" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model)
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    runtime.run("First run")

    loaded = Clarity::Runtime(MockModel).load(store: store, log_agent: log_agent)
    loaded.should be_a(Clarity::Runtime(MockModel))
    loaded.store.count.should eq(store.count)
  end
end
