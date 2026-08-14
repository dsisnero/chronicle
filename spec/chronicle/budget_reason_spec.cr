require "../spec_helper"

describe Chronicle::RuntimeReason do
  it "returns the generic budget.exhausted reason when the dimension is nil" do
    Chronicle::RuntimeReason.budget_reason(nil).should eq("budget.exhausted")
  end

  it "maps the dimension-specific reasons from the explicit map" do
    Chronicle::RuntimeReason.budget_reason("max_tool_calls").should eq("budget.tool_calls_exhausted")
    Chronicle::RuntimeReason.budget_reason("max_cost_usd").should eq("budget.cost_exhausted")
    Chronicle::RuntimeReason.budget_reason("max_llm_calls").should eq("budget.llm_calls_exhausted")
  end

  it "derives the default reason by stripping the max_ prefix and suffixing _exhausted" do
    Chronicle::RuntimeReason.budget_reason("max_events").should eq("budget.events_exhausted")
    Chronicle::RuntimeReason.budget_reason("max_seconds").should eq("budget.seconds_exhausted")
    Chronicle::RuntimeReason.budget_reason("max_patches").should eq("budget.patches_exhausted")
    Chronicle::RuntimeReason.budget_reason("max_depth").should eq("budget.depth_exhausted")
    Chronicle::RuntimeReason.budget_reason("max_behavior_calls").should eq("budget.behavior_calls_exhausted")
  end

  it "passes through a non max_-prefixed name unchanged" do
    Chronicle::RuntimeReason.budget_reason("custom").should eq("budget.custom_exhausted")
  end

  it "covers every KNOWN_LIMITS dimension (reason-codes doc parity)" do
    expected = {
      "max_events"         => "budget.events_exhausted",
      "max_behavior_calls" => "budget.behavior_calls_exhausted",
      "max_llm_calls"      => "budget.llm_calls_exhausted",
      "max_tool_calls"     => "budget.tool_calls_exhausted",
      "max_patches"        => "budget.patches_exhausted",
      "max_depth"          => "budget.depth_exhausted",
      "max_seconds"        => "budget.seconds_exhausted",
      "max_cost_usd"       => "budget.cost_exhausted",
    }
    Chronicle::Budget::KNOWN_LIMITS.each do |dimension|
      Chronicle::RuntimeReason.budget_reason(dimension).should eq(expected[dimension])
    end
  end
end
