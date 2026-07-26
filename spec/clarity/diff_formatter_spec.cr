require "../spec_helper"

describe Clarity::DiffFormatter do
  it "formats an empty diff as no changes" do
    diff = Clarity::GraphDiff.new([] of String, [] of String, [] of String, [] of String)
    output = Clarity::DiffFormatter.format(diff)
    output.should contain("no changes")
  end

  it "lists added objects" do
    diff = Clarity::GraphDiff.new(
      ["obj_001", "obj_002"],
      [] of String,
      [] of String,
      [] of String,
    )
    output = Clarity::DiffFormatter.format(diff)
    output.should contain("+ obj_001")
    output.should contain("+ obj_002")
  end

  it "lists removed objects" do
    diff = Clarity::GraphDiff.new(
      [] of String,
      ["obj_003"],
      [] of String,
      [] of String,
    )
    output = Clarity::DiffFormatter.format(diff)
    output.should contain("- obj_003")
  end

  it "handles combined add/remove" do
    diff = Clarity::GraphDiff.new(
      ["obj_a"],
      ["obj_r"],
      ["rel_a"],
      ["rel_r"],
    )
    output = Clarity::DiffFormatter.format(diff)
    output.should contain("+ obj_a")
    output.should contain("- obj_r")
    output.should contain("+ rel_a")
    output.should contain("- rel_r")
  end
end
