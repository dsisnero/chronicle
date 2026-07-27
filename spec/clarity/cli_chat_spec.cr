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

describe "CLI chat" do
  it "reports missing API key without crash" do
    output = Clarity::CLI.run(["chat"])
    output.should contain("API_KEY")
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
    _model, command = tui.update(Tea::Key.new(code: Tea::KeyEnter))
    tui.update(command.not_nil!.call.not_nil!)

    # Should have recorded events
    store.count.should be >= 1
    events = store.iter_events
    events.any? { |e| e.type == "goal.created" }.should be_true
    events.any? { |e| e.type == "command.accepted" && e.actor == "channel.tui" }.should be_true
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
    _model, command = tui.update(Tea::Key.new(code: Tea::KeyEnter))
    tui.update(command.not_nil!.call.not_nil!)

    view = tui.view
    view.content.should contain(">>> Hi")
    view.content.should contain("Mock response")

    restored_tui = Clarity::TUI::BubbleTeaModel.new(runtime: runtime)
    restored_view = restored_tui.view
    restored_view.content.should contain(">>> Hi")
    restored_view.content.should contain("Mock response")
  end
end
