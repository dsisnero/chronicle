require "../spec_helper"

describe Clarity::TUI::StandaloneBubbleTeaModel do
  it "implements Tea::Model interface" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new
    model.should be_a(Tea::Model)
  end

  it "init returns nil command" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new
    model.init.should be_nil
  end

  it "update handles KeyPressMsg with printable char" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new
    key = Tea::Key.new(text: "H")
    model.update(key)
    model.program.input_buffer.should eq("H")
    Ansi.strip(model.view.content).should contain("> H")
  end

  it "update handles backspace key" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new
    model.update(Tea::Key.new(text: "A"))
    model.update(Tea::Key.new(text: "B"))

    key = Tea::Key.new(code: Tea::KeyBackspace)
    model.update(key)
    model.program.input_buffer.should eq("A")
  end

  it "update handles enter key" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new
    model.update(Tea::Key.new(text: "H"))

    key = Tea::Key.new(code: Tea::KeyEnter)
    model.update(key)
    model.program.state.should eq(Clarity::TUI::State::Processing)
    model.program.messages.first.content.should eq("H")
  end

  it "view returns a Tea::View with header" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new
    view = model.view
    view.should be_a(Tea::View)
    view.content.should contain("Clarity Agent")
  end

  it "uses Bubbles' text input for terminal editing" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new

    model.input.should be_a(Bubbles::TextInput::Model)
  end

  it "returns itself and a command from update" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new

    updated, command = model.update(Tea::ModeReportMsg.new(2026, 2))

    updated.should be(model)
    command.should be_nil
  end

  it "quits and restores the terminal on Ctrl-C" do
    model = Clarity::TUI::StandaloneBubbleTeaModel.new

    updated, command = model.update(Tea::Key.new(code: 'c'.ord, mod: Ultraviolet::ModCtrl))

    updated.should be(model)
    model.program.state.should eq(Clarity::TUI::State::Done)
    command.should_not be_nil
    command.not_nil!.call.should be_a(Tea::QuitMsg)
  end
end
