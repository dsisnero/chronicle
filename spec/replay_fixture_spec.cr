require "./spec_helper"
require "./support/replay_fixture"

describe "replay fixture" do
  it "contains successful and failed recorded effects in causal order" do
    log = Clarity::EventLog.new
    ReplayFixture.events.each { |event| log.append(event) }

    log.events.map(&.type).should eq(["goal.created", "model.responded", "tool.failed"])
    Clarity::RunProjection.replay(log.events).objective.should eq("verify replay without live effects")
  end
end
