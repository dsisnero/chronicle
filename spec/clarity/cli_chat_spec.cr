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

describe "CLI chat" do
  it "parses the chat command without error" do
    output = Clarity::CLI.run(["chat"])
    output.should_not contain("ERROR")
  end

  it "runs a headless chat with a prompt and records events" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model, preamble: "You are helpful.")
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    tui = Clarity::TUI::BubbleTeaModel.new(runtime: runtime)
    tui.init

    # Simulate typing a message
    tui.update(Tea::Key.new(text: "Hello"))
    tui.update(Tea::Key.new(code: Tea::KeyEnter))

    # Should have recorded events
    store.count.should be >= 1
    events = store.iter_events
    events.any? { |e| e.type == "goal.created" }.should be_true
  end

  it "displays agent response after submitting prompt" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model, preamble: "Answer concisely.")
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    tui = Clarity::TUI::BubbleTeaModel.new(runtime: runtime)
    tui.init

    tui.update(Tea::Key.new(text: "Hi"))
    tui.update(Tea::Key.new(code: Tea::KeyEnter))

    view = tui.view
    view.content.should contain(">>> Hi")
    view.content.should contain("Mock response")
  end
end
