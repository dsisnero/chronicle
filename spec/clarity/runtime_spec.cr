require "../spec_helper"

class MockModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

private alias T = Clarity::Routing::Target

describe Clarity::Runtime do
  it "runs a prompt and records goal.created + effect events" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model, preamble: "You are helpful.")
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    runtime.run("Hello")

    store.count.should be >= 1
    events = store.iter_events
    events.any? { |e| e.type == "goal.created" }.should be_true
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
