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
end
