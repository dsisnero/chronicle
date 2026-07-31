require "../spec_helper"

# Pack + policy specs. Ported from activegraph packs/__init__.py (Pack, PackPolicy)
# and policy.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

class PackModel
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

module PackSpecHelper
  extend self

  def runtime(tools : Array(Clarity::Tool) = [] of Clarity::Tool) : Clarity::Runtime(PackModel)
    store = Clarity::MemoryEventStore.new
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "Use tools.")
    la = Clarity::LogAgent(PackModel).new(agent, store: store, max_turns: 2)
    Clarity::Runtime(PackModel).new(store: store, log_agent: la, tools: tools)
  end
end

describe Clarity::Pack do
  it "holds pack identity and contents" do
    search = Clarity::Tool.new("search", "search") { |a| "{}" }
    pack = Clarity::Pack.new(
      name: "diligence", version: "1.0.0",
      description: "diligence pack",
      object_types: ["claim", "source"], tools: [search],
    )
    pack.name.should eq("diligence")
    pack.version.should eq("1.0.0")
    pack.object_types.should eq(["claim", "source"])
    pack.tools.map(&.name).should eq(["search"])
  end

  it "validates name and version" do
    expect_raises(Clarity::PackError, /name/) do
      Clarity::Pack.new(name: "Bad Name", version: "1.0.0")
    end
    expect_raises(Clarity::PackError, /version/) do
      Clarity::Pack.new(name: "ok", version: "")
    end
  end
end

describe Clarity::Runtime do
  it "loads a pack, registers its tools, and records a pack.loaded event" do
    search = Clarity::Tool.new("search", "search") { |a| "{}" }
    pack = Clarity::Pack.new(name: "diligence", version: "1.0.0", tools: [search])
    runtime = PackSpecHelper.runtime

    runtime.load_pack(pack)
    runtime.loaded_packs.should eq(["diligence"])
    runtime.get_tool("search").should_not be_nil
    runtime.store.iter_events.any? { |e| e.type == "pack.loaded" }.should be_true
  end

  it "surfaces pack policies and approval routing" do
    policy = Clarity::Policy.new(
      behavior: "research",
      can_call_tool: ["search"],
      requires_approval: ["search"],
    )
    pack = Clarity::Pack.new(name: "p", version: "1.0.0", policies: [policy])
    runtime = PackSpecHelper.runtime

    runtime.load_pack(pack)
    runtime.tool_requires_approval?("search").should be_true
    runtime.tool_requires_approval?("web_fetch").should be_false
  end

  it "routes a policy-required tool call through pending approval instead of executing" do
    executed = Atomic(Bool).new(false)
    search = Clarity::Tool.new("search", "search") do |a|
      executed.set(true)
      %({"results":[]})
    end
    policy = Clarity::Policy.new(requires_approval: ["search"])
    pack = Clarity::Pack.new(name: "p", version: "1.0.0", tools: [search], policies: [policy])
    runtime = PackSpecHelper.runtime

    runtime.load_pack(pack)
    runtime.run("Do it")

    executed.get.should be_false
    runtime.pending_approvals.any? { |a| a.summary.includes?("search") }.should be_true
  end
end
