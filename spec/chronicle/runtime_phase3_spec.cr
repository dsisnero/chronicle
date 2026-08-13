require "../spec_helper"

# Phase 3 — Runtime execution surface specs. Ported from activegraph
# runtime/runtime.py bounded-run, budget, approval, authority, and trace
# surfaces (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

class Phase3Model
  include Crig::Completion::CompletionModel

  @calls = 0

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    if @calls == 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.tool_call("tc_1", "search", JSON.parse(%({"q":"test"})))
        ),
        Crig::Completion::Usage.new(input_tokens: 3, output_tokens: 1),
        "raw",
        "msg_1",
      )
    else
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text("Tool done")
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_2",
      )
    end
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module Phase3SpecHelper
  extend self

  def runtime(model = Phase3Model.new, tools : Array(Chronicle::Tool) = [] of Chronicle::Tool, budget : Chronicle::Runtime::Budget = Chronicle::Runtime::Budget.new) : Chronicle::Runtime(Phase3Model)
    store = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(Phase3Model).new(model: model, preamble: "Use tools.")
    la = Chronicle::LogAgent(Phase3Model).new(agent, store: store, max_turns: 2)
    Chronicle::Runtime(Phase3Model).new(store: store, log_agent: la, tools: tools, budget: budget)
  end
end

describe Chronicle::Runtime do
  it "runs a bounded quantum of loop steps" do
    runtime = Phase3SpecHelper.runtime(tools: [Chronicle::Tool.new("search", "search") { |a| %({"results":[]}) }])
    runtime.run_quantum("Quantum me", steps: 2)
    runtime.response.should eq("")

    runtime2 = Phase3SpecHelper.runtime(tools: [Chronicle::Tool.new("search", "search") { |a| %({"results":[]}) }])
    runtime2.run_quantum("Quantum me", steps: 4)
    runtime2.response.should eq("Tool done")
  end

  it "runs until idle by default" do
    runtime = Phase3SpecHelper.runtime(tools: [Chronicle::Tool.new("search", "search") { |a| %({"results":[]}) }])
    runtime.run_until_idle("Idle me")
    runtime.response.should eq("Tool done")
  end

  it "reports and resets the budget" do
    runtime = Phase3SpecHelper.runtime(budget: Chronicle::Runtime::Budget.new(max_events: 10))
    runtime.budget_remaining.should eq(10_i64)
    runtime.start_budget(20)
    runtime.budget_remaining.should eq(20_i64)
  end

  it "looks up registered tools" do
    search = Chronicle::Tool.new("search", "search") { |a| "{}" }
    runtime = Phase3SpecHelper.runtime(tools: [search])
    runtime.get_tool("search").should_not be_nil
    runtime.get_tool("nope").should be_nil
  end

  it "tracks pending approvals and resolves them" do
    runtime = Phase3SpecHelper.runtime
    runtime.add_pending_approval(Chronicle::ApprovalRequest.new("req_1", Chronicle::ApprovalKind::Shell, "run command"))
    runtime.pending_approvals.map(&.id).should eq(["req_1"])
    result = runtime.approve("req_1")
    result.approved?.should be_true
    runtime.pending_approvals.should be_empty
  end

  it "enforces an authority ceiling (CONTRACT v1.9 action-class path)" do
    runtime = Phase3SpecHelper.runtime
    runtime.authority_ceiling.should eq("none")
    runtime.evaluate_capability_authority(capability: "x.y", action_class: "R0").decision.should eq("require_approval")

    runtime.set_authority_ceiling("R1", actor: "owner", reason: "raise")
    runtime.authority_ceiling.should eq("R1")
    runtime.evaluate_capability_authority(capability: "x.y", action_class: "R0").decision.should eq("auto_approve")
    runtime.evaluate_capability_authority(capability: "x.y", action_class: "R1").decision.should eq("auto_approve")
    runtime.evaluate_capability_authority(capability: "x.y", action_class: "R2").decision.should eq("require_approval")
  end

  it "exports a trace and reports status" do
    runtime = Phase3SpecHelper.runtime(tools: [Chronicle::Tool.new("search", "search") { |a| %({"results":[]}) }])
    runtime.run("Trace me")

    trace = JSON.parse(runtime.export_trace).as_h
    trace["run_id"].as_s.should eq("default")
    trace["events"].as_a.size.should be >= 1

    status = runtime.status
    status.events_processed.should be >= 1
    status.run_id.should eq("default")
  end
end
