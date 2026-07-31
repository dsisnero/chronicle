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

describe "LogAgent with EventStore" do
  it "stores a goal.created event on start" do
    store = Chronicle::MemoryEventStore.new
    agent = make_agent(store)

    agent.start(Crig::Completion::Message.user("Hello"))

    events = store.iter_events
    events.any? { |e| e.type == "goal.created" }.should be_true
  end

  it "stores effect.requested for model turn" do
    store = Chronicle::MemoryEventStore.new
    agent = make_agent(store)
    agent.start(Crig::Completion::Message.user("Hello"))
    step = agent.next_step

    agent.record_model_effect(step)
    events = store.iter_events
    events.any? { |e| e.type == "effect.requested" }.should be_true
  end

  it "stores effect.responded for model response" do
    store = Chronicle::MemoryEventStore.new
    agent = make_agent(store)
    agent.start(Crig::Completion::Message.user("Hello"))
    step = agent.next_step

    effect = agent.record_model_effect(step)

    choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
      Crig::Completion::AssistantContent.text("Hello back")
    )
    turn = Crig::ModelTurn.new(
      message_id: "msg_001", choice: choice,
      usage: Crig::Completion::Usage.new,
      allowed_tools: [] of String,
    )
    agent.model_response(turn, result_hash: effect.not_nil!.content_hash)

    events = store.iter_events
    events.any? { |e| e.type == "effect.responded" }.should be_true
  end

  it "recovers agent run from stored events" do
    store = Chronicle::MemoryEventStore.new

    # First run
    agent = make_agent(store, preamble: "You are helpful.")
    agent.start(Crig::Completion::Message.user("First message"))
    step = agent.next_step
    effect = agent.record_model_effect(step)

    choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
      Crig::Completion::AssistantContent.text("First response")
    )
    turn = Crig::ModelTurn.new(
      message_id: "msg_001", choice: choice,
      usage: Crig::Completion::Usage.new,
      allowed_tools: [] of String,
    )
    agent.model_response(turn, result_hash: effect.not_nil!.content_hash)

    step2 = agent.next_step
    step2.done?.should be_true

    # Verify events were stored
    store.count.should be >= 2
    store.get_event("goal_created_1").should_not be_nil
  end

  it "persists tool effect requests to store" do
    store = Chronicle::MemoryEventStore.new
    agent = make_agent(store, preamble: "Use tools.")

    # Create a tool call scenario
    agent.start(Crig::Completion::Message.user("Search for data"))
    step = agent.next_step
    effect = agent.record_model_effect(step)

    choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
      Crig::Completion::AssistantContent.tool_call("tc_001", "search", JSON.parse(%({"q":"test"})))
    )
    turn = Crig::ModelTurn.new(
      message_id: "msg_002", choice: choice,
      usage: Crig::Completion::Usage.new,
      allowed_tools: ["search"],
    )
    agent.model_response(turn, result_hash: effect.not_nil!.content_hash)

    tool_step = agent.next_step
    agent.record_tool_effects(tool_step)

    events = store.iter_events
    tool_events = events.select { |e| e.type == "effect.requested" }
    tool_events.size.should be >= 2 # model + tool
  end
end

private def make_agent(store, preamble = "You are helpful.")
  model = MockModel.new
  crig_agent = Crig::Agent(MockModel).new(
    model: model, preamble: preamble,
  )
  Chronicle::LogAgent(MockModel).new(crig_agent, store: store)
end
