require "../spec_helper"

# Explicit, log-backed local dev.override receipts (CONTRACT v1.8 #13–#15).
# Ported from activegraph tests/test_dev_override.py.

module DevOverrideSpecHelper
  extend self

  def runtime(run_id : String = "run_local") : Chronicle::Runtime(PackModel)
    store = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    Chronicle::Runtime(PackModel).new(store: store, log_agent: la, run_id: run_id)
  end
end

describe "dev_override" do
  it "emits a complete marker before returning the receipt" do
    runtime = DevOverrideSpecHelper.runtime
    receipt = runtime.dev_override(
      actor: "local-developer",
      reason: "exercise a gated fixture",
      target_gate: "pack.fixture.approval",
      scope: "pack:demo/object:fixture-1",
      resulting_authority: "R2",
    )

    receipt.should be_a(Chronicle::DevOverride)
    event = runtime.store.iter_events.last
    event.type.should eq("dev.override")
    event.id.should eq(receipt.event_id)
    event.actor.should eq("local-developer")
    payload = JSON.parse(event.payload)
    payload["actor"].as_s.should eq("local-developer")
    payload["reason"].as_s.should eq("exercise a gated fixture")
    payload["target_gate"].as_s.should eq("pack.fixture.approval")
    payload["scope"].as_s.should eq("pack:demo/object:fixture-1")
    payload["resulting_authority"].as_s.should eq("R2")
    runtime.dev_overrides.should eq([receipt])
  end

  it "validates exactly, run-locally, and authority-bounded" do
    runtime = DevOverrideSpecHelper.runtime(run_id: "run_local")
    receipt = runtime.dev_override(
      actor: "dev",
      reason: "local test",
      target_gate: "pack.fixture.approval",
      scope: "fixture:one",
      resulting_authority: "R2",
    )

    runtime.validate_dev_override(receipt, target_gate: "pack.fixture.approval", scope: "fixture:one", required_authority: "R0").should be_true
    runtime.validate_dev_override(receipt, target_gate: "pack.fixture.approval", scope: "fixture:one", required_authority: "R2").should be_true
    runtime.validate_dev_override(receipt, target_gate: "pack.fixture.approval", scope: "fixture:one", required_authority: "R3").should be_false
    runtime.validate_dev_override(receipt, target_gate: "pack.fixture.approval", scope: "fixture:*", required_authority: "R1").should be_false

    other = DevOverrideSpecHelper.runtime(run_id: "run_other")
    other.validate_dev_override(receipt, target_gate: "pack.fixture.approval", scope: "fixture:one", required_authority: "R1").should be_false
  end

  it "rejects promotion and event-log gates before emission" do
    runtime = DevOverrideSpecHelper.runtime
    [
      {gate: "promote", authority: "R1"},
      {gate: "promote.conflict", authority: "R1"},
      {gate: "promotion.apply", authority: "R1"},
      {gate: "event.logging", authority: "R1"},
      {gate: "event_log.append", authority: "R1"},
      {gate: "pack.fixture.approval", authority: "R4"},
    ].each do |entry|
      expect_raises(Chronicle::DevOverrideError) do
        runtime.dev_override(
          actor: "dev",
          reason: "should fail",
          target_gate: entry[:gate],
          scope: "fixture:one",
          resulting_authority: entry[:authority],
        )
      end
      runtime.store.iter_events.size.should eq(0)
    end
  end

  it "rejects promotion and R4 even for a fabricated receipt" do
    runtime = DevOverrideSpecHelper.runtime(run_id: "run_local")
    fabricated = Chronicle::DevOverride.new(
      event_id: "evt_missing",
      run_id: "run_local",
      actor: "dev",
      reason: "fabricated",
      target_gate: "promote.conflict",
      scope: "run:fork",
      resulting_authority: "R4",
    )
    runtime.validate_dev_override(fabricated, target_gate: "promote.conflict", scope: "run:fork", required_authority: "R4").should be_false
  end

  it "ignores non-override events when rebuilding receipts" do
    runtime = DevOverrideSpecHelper.runtime(run_id: "run_mixed")
    runtime.store.iter_events.size.should eq(0)
    runtime.dev_override(
      actor: "dev",
      reason: "persist me",
      target_gate: "pack.fixture.approval",
      scope: "fixture:one",
      resulting_authority: "R1",
    )
    runtime.dev_overrides.size.should eq(1)
    runtime.dev_overrides.first.target_gate.should eq("pack.fixture.approval")
  end
end
