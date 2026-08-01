require "../spec_helper"

# Pack + policy specs. Ported from activegraph packs/__init__.py (Pack, PackPolicy)
# and policy.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

module PackSpecHelper
  extend self

  def runtime(
    tools : Array(Chronicle::Tool) = [] of Chronicle::Tool,
    tool_approval_policies : Array(Chronicle::Policy) = [] of Chronicle::Policy,
  ) : Chronicle::Runtime(PackModel)
    store = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "Use tools.")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 2)
    Chronicle::Runtime(PackModel).new(
      store: store, log_agent: la, tools: tools,
      tool_approval_policies: tool_approval_policies,
    )
  end
end

describe Chronicle::Packs::Pack do
  it "holds pack identity and contents" do
    search = Chronicle::Tool.new("search", "search") { |a| "{}" }
    pack = Chronicle::Packs::Pack.new(
      name: "diligence", version: "1.0.0",
      description: "diligence pack",
      object_types: [Chronicle::Packs::ObjectType.new("claim"), Chronicle::Packs::ObjectType.new("source")],
      tools: [search],
    )
    pack.name.should eq("diligence")
    pack.version.should eq("1.0.0")
    pack.object_types.map(&.name).should eq(["claim", "source"])
    pack.tools.map(&.name).should eq(["search"])
  end

  it "validates name and version" do
    expect_raises(Chronicle::Packs::PackValidationError, /name/) do
      Chronicle::Packs::Pack.new(name: "Bad Name", version: "1.0.0")
    end
    expect_raises(Chronicle::Packs::PackValidationError, /version/) do
      Chronicle::Packs::Pack.new(name: "ok", version: "")
    end
  end

  it "equates and hashes by (name, version)" do
    a = Chronicle::Packs::Pack.new(name: "demo", version: "0.1.0")
    b = Chronicle::Packs::Pack.new(name: "demo", version: "0.1.0")
    c = Chronicle::Packs::Pack.new(name: "demo", version: "0.2.0")
    a.should eq(b)
    a.should_not eq(c)
    a.hash.should eq(b.hash)
  end

  it "rejects duplicate behavior names" do
    behavior = Chronicle::Packs::PackBehavior.new(name: "ping")
    expect_raises(Chronicle::Packs::PackValidationError, /duplicate behavior/) do
      Chronicle::Packs::Pack.new(
        name: "demo", version: "0.1.0",
        behaviors: [behavior, behavior],
      )
    end
  end
end

describe Chronicle::Runtime do
  it "loads a pack, registers its tools, and records a pack.loaded event" do
    search = Chronicle::Tool.new("search", "search") { |a| "{}" }
    pack = Chronicle::Packs::Pack.new(name: "diligence", version: "1.0.0", tools: [search])
    runtime = PackSpecHelper.runtime

    runtime.load_pack(pack).should be_true
    runtime.loaded_packs.should eq(["diligence"])
    runtime.get_tool("search").should_not be_nil
    runtime.store.iter_events.any? { |e| e.type == "pack.loaded" }.should be_true
  end

  it "is idempotent on (name, version)" do
    pack = Chronicle::Packs::Pack.new(name: "diligence", version: "1.0.0")
    runtime = PackSpecHelper.runtime
    runtime.load_pack(pack).should be_true
    runtime.load_pack(pack).should be_false
    runtime.store.iter_events.count { |e| e.type == "pack.loaded" }.should eq(1)
  end

  it "raises on a version conflict" do
    v1 = Chronicle::Packs::Pack.new(name: "demo", version: "0.1.0")
    v2 = Chronicle::Packs::Pack.new(name: "demo", version: "0.2.0")
    runtime = PackSpecHelper.runtime
    runtime.load_pack(v1)
    expect_raises(Chronicle::Packs::PackVersionConflictError) do
      runtime.load_pack(v2)
    end
  end

  it "surfaces tool approval routing from runtime policies" do
    policy = Chronicle::Policy.new(
      behavior: "research",
      can_call_tool: ["search"],
      requires_approval: ["search"],
    )
    runtime = PackSpecHelper.runtime(tool_approval_policies: [policy])

    runtime.tool_requires_approval?("search").should be_true
    runtime.tool_requires_approval?("web_fetch").should be_false
  end

  it "routes a policy-required tool call through pending approval instead of executing" do
    executed = Atomic(Bool).new(false)
    search = Chronicle::Tool.new("search", "search") do |a|
      executed.set(true)
      %({"results":[]})
    end
    policy = Chronicle::Policy.new(requires_approval: ["search"])
    runtime = PackSpecHelper.runtime(tools: [search], tool_approval_policies: [policy])

    runtime.run("Do it")

    executed.get.should be_false
    runtime.pending_approvals.any? { |a| a.summary.includes?("search") }.should be_true
  end
end
