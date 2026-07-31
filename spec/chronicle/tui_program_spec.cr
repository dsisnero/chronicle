require "../spec_helper"

describe Chronicle::TUI::Program do
  it "initializes with Input state and empty input buffer" do
    model = Chronicle::TUI::Program.new
    model.state.should eq(Chronicle::TUI::State::Input)
    model.input_buffer.should eq("")
  end

  it "accumulates characters in input buffer" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('H')
    model = model.handle_key('i')
    model.input_buffer.should eq("Hi")
    model.state.should eq(Chronicle::TUI::State::Input)
  end

  it "submits on enter and transitions to Processing" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('H')
    model = model.handle_enter
    model.input_buffer.should eq("")
    model.state.should eq(Chronicle::TUI::State::Processing)
    model.messages.size.should eq(1)
    model.messages.first.content.should eq("H")
  end

  it "handles backspace" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('A')
    model = model.handle_key('B')
    model = model.handle_backspace
    model.input_buffer.should eq("A")
  end

  it "processes agent response and returns to Input state" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('H').handle_enter
    model = model.handle_response("Hello back")
    model.state.should eq(Chronicle::TUI::State::Input)
    model.messages.last.content.should eq("Hello back")
  end

  it "rebuilds visible chat history from persisted chat.message events" do
    events = [
      Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "chat_1",
        type: "chat.message", actor: "user", caused_by: nil,
        timestamp: Time.utc, payload: %({"role":"user","content":"Hello"}),
      ),
      Chronicle::Event.new(
        schema_version: 1_u16, sequence: 2_u64, id: "chat_2",
        type: "chat.message", actor: "agent", caused_by: "chat_1",
        timestamp: Time.utc, payload: %({"role":"assistant","content":"Hi there"}),
      ),
    ]

    model = Chronicle::TUI::Program.from_events(events)

    model.messages.map(&.role).should eq(["user", "assistant"])
    model.render.should contain(">>> Hello")
    model.render.should contain("Hi there")
  end

  it "handles approval prompt with y/n keys" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('R').handle_enter
    model = model.handle_tool_call("shell", %({"cmd":"ls"}), requires_approval: true)
    model.pending_approval.should_not be_nil

    model = model.handle_key('y')
    model.pending_approval.should be_nil
    model.messages.last.role.should eq("approval")
    model.state.should eq(Chronicle::TUI::State::Processing)
  end

  it "rejects approval with n key" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('R').handle_enter
    model = model.handle_tool_call("shell", %({"cmd":"ls"}), requires_approval: true)

    model = model.handle_key('n')
    model.pending_approval.should be_nil
    model.messages.last.role.should eq("rejection")
    model.state.should eq(Chronicle::TUI::State::Input)
  end

  it "view contains messages and input prompt" do
    model = Chronicle::TUI::Program.new
    model = model.handle_key('H').handle_enter
    model = model.handle_response("Hello world")
    view = model.render
    view.should contain("Hello world")
    view.should contain(">")
  end

  it "exits on ctrl+c or /quit" do
    model = Chronicle::TUI::Program.new
    model = model.handle_quit
    model.state.should eq(Chronicle::TUI::State::Done)
  end
end
