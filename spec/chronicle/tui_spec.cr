require "../spec_helper"

describe Chronicle::TUI do
  it "creates an initial model in Input state" do
    model = Chronicle::TUI::Model.new
    model.state.should eq(Chronicle::TUI::State::Input)
    model.messages.should be_empty
  end

  it "adds a user message on input" do
    model = Chronicle::TUI::Model.new
    model = model.handle_input("Hello, agent!")
    model.messages.size.should eq(1)
    model.messages.first.role.should eq("user")
    model.messages.first.content.should eq("Hello, agent!")
    model.state.should eq(Chronicle::TUI::State::Processing)
  end

  it "adds an agent response message" do
    model = Chronicle::TUI::Model.new
    model = model.handle_input("Hi")
    model = model.handle_response("Hello! How can I help?")
    model.messages.size.should eq(2)
    model.messages.last.role.should eq("assistant")
    model.messages.last.content.should eq("Hello! How can I help?")
    model.state.should eq(Chronicle::TUI::State::Input)
  end

  it "adds a tool call message" do
    model = Chronicle::TUI::Model.new
    model = model.handle_input("Search")
    model = model.handle_tool_call("web_search", %({"q":"chronicle"}))
    model.messages.size.should eq(2)
    model.messages.last.role.should eq("tool_call")
    model.messages.last.tool_name.should eq("web_search")
  end

  it "view renders messages" do
    model = Chronicle::TUI::Model.new
    model = model.handle_input("Hello")
    model = model.handle_response("Hi there")
    view = model.render
    view.should contain("Hello")
    view.should contain("Hi there")
  end

  it "handles approval for ask tools" do
    model = Chronicle::TUI::Model.new
    model = model.handle_input("Run shell")
    model = model.handle_tool_call("shell", %({"cmd":"ls"}), requires_approval: true)
    model.pending_approval.should_not be_nil
    model.pending_approval.not_nil!.tool_name.should eq("shell")

    model = model.approve_pending
    model.pending_approval.should be_nil
    model.messages.last.role.should eq("approval")
  end

  it "rejects a pending approval" do
    model = Chronicle::TUI::Model.new
    model = model.handle_input("Run")
    model = model.handle_tool_call("shell", %({"cmd":"ls"}), requires_approval: true)
    model = model.reject_pending
    model.pending_approval.should be_nil
    model.messages.last.role.should eq("rejection")
  end
end
