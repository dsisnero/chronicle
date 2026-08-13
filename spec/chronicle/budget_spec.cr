require "../spec_helper"

describe Chronicle::Budget do
  it "exposes the known limit dimensions" do
    Chronicle::Budget::KNOWN_LIMITS.should eq([
      "max_events", "max_behavior_calls", "max_llm_calls", "max_tool_calls",
      "max_patches", "max_depth", "max_seconds", "max_cost_usd",
    ])
  end

  it "defaults every dimension to unlimited" do
    budget = Chronicle::Budget.new
    budget.remaining.should be_true
    budget.has_cost_limit.should be_false
    budget.cost_remaining_amount.should be_nil
    snap = budget.snapshot
    snap.limits.values.all?(&.nil?).should be_true
    snap.cost_limit_usd.should be_nil
  end

  it "is exhausted when a consumed counter reaches its limit" do
    budget = Chronicle::Budget.new(limits: {"max_events" => 2.0})
    budget.consume("max_events")
    budget.remaining.should be_true
    budget.consume("max_events")
    budget.remaining.should be_false
    budget.exhausted_by.should eq("max_events")
  end

  it "tracks the cost ceiling in cost-limited mode" do
    budget = Chronicle::Budget.new(limits: {"max_cost_usd" => "10.00"})
    budget.has_cost_limit.should be_true
    budget.cost_limit.should eq("10.00")
    budget.add_cost("9.50")
    budget.cost_remaining("0.50").should be_true
    budget.cost_remaining("1.00").should be_false
    budget.cost_remaining_amount.should eq("0.5")
  end

  it "adds sub-cent costs without float drift (CONTRACT v0.6 #9)" do
    budget = Chronicle::Budget.new(limits: {"max_cost_usd" => "100.00"})
    budget.add_cost("0.1")
    budget.add_cost("0.2")
    budget.add_cost("0.7")
    budget.cost_used.should eq("1.0")
  end

  it "exhausts when accumulated cost reaches the ceiling" do
    budget = Chronicle::Budget.new(limits: {"max_cost_usd" => "0.001"})
    budget.add_cost("0.001")
    budget.remaining.should be_false
    budget.exhausted_by.should eq("max_cost_usd")
  end

  it "mark_exhausted sets the authoritative reason for recorded replay" do
    budget = Chronicle::Budget.new
    budget.mark_exhausted("max_tool_calls")
    budget.exhausted_by.should eq("max_tool_calls")
  end

  it "snapshot mirrors used, limits, and cost strings" do
    budget = Chronicle::Budget.new(limits: {"max_events" => 3.0, "max_cost_usd" => "5.00"})
    budget.consume("max_events")
    budget.add_cost("1.25")
    snap = budget.snapshot
    snap.used["max_events"].should eq(1.0)
    snap.limits["max_events"].should eq(3.0)
    snap.limits["max_cost_usd"].should eq(5.0)
    snap.cost_used_usd.should eq("1.25")
    snap.cost_limit_usd.should eq("5.00")
  end

  it "renders unlimited dimensions as nil in the snapshot" do
    budget = Chronicle::Budget.new(limits: {"max_depth" => 4.0})
    snap = budget.snapshot
    snap.limits["max_depth"].should eq(4.0)
    snap.limits["max_events"].should be_nil
  end
end
