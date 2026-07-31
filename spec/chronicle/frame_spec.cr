require "../spec_helper"

describe Chronicle::Frame do
  it "creates a frame with a goal" do
    frame = Chronicle::Frame.new(goal: "Review code for security issues")
    frame.goal.should eq("Review code for security issues")
  end

  it "auto-generates an id" do
    frame = Chronicle::Frame.new(goal: "test")
    frame.id.should_not be_nil
    frame.id.should_not be_empty
  end

  it "accepts constraints and success criteria" do
    frame = Chronicle::Frame.new(
      goal: "Deploy microservice",
      constraints: ["must pass CI", "no breaking changes"],
      success_criteria: ["all tests pass", "deployment green"],
    )
    frame.constraints.size.should eq(2)
    frame.success_criteria.size.should eq(2)
  end

  it "FrameStack push and pop" do
    stack = Chronicle::FrameStack.new
    stack.size.should eq(0)

    f1 = Chronicle::Frame.new(goal: "first")
    f2 = Chronicle::Frame.new(goal: "second")

    stack.push(f1)
    stack.size.should eq(1)
    stack.current.not_nil!.goal.should eq("first")

    stack.push(f2)
    stack.size.should eq(2)
    stack.current.not_nil!.goal.should eq("second")

    popped = stack.pop
    popped.goal.should eq("second")
    stack.size.should eq(1)
    stack.current.not_nil!.goal.should eq("first")
  end

  it "returns nil current on empty stack" do
    stack = Chronicle::FrameStack.new
    stack.current.should be_nil
  end
end
