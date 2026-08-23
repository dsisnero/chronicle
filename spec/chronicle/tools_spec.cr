require "../spec_helper"

# Tool abstraction + graph_query tool + runtime tool invocation specs.
# Ported from activegraph tools/base.py, tools/decorators.py, tools/graph_query.py,
# tools/cache.py (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).

module ToolSpecHelper
  extend self

  def obj_event(seq : UInt64, id : String, type : String, data : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "evt_#{seq}",
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"id":"#{id}","type":"#{type}","data":#{data}}),
    )
  end

  def graph(events : Array(Chronicle::Event)) : Chronicle::GraphProjection
    events.reduce(Chronicle::GraphProjection.empty) { |g, e| g.apply(e) }
  end
end

class ToolCallingModel
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

describe Chronicle do
  describe "make_graph_query_tool" do
    it "returns object refs matching the type and where filter" do
      g = ToolSpecHelper.graph([
        ToolSpecHelper.obj_event(1_u64, "claim#1", "claim", %({"text":"x","confidence":0.9})),
        ToolSpecHelper.obj_event(2_u64, "claim#2", "claim", %({"text":"y","confidence":0.4})),
        ToolSpecHelper.obj_event(3_u64, "task#1", "task", %({"title":"t"})),
      ])
      tool = Chronicle.make_graph_query_tool(g)
      output = tool.call(%({"object_type":"claim","where":{"confidence":{">":0.5}}}))
      parsed = JSON.parse(output).as_h
      refs = parsed["refs"].as_a
      refs.size.should eq(1)
      refs[0].as_h["id"].as_s.should eq("claim#1")
      parsed["truncated"].as_bool.should be_false
    end

    it "truncates results beyond the limit" do
      g = ToolSpecHelper.graph([
        ToolSpecHelper.obj_event(1_u64, "claim#1", "claim", %({})),
        ToolSpecHelper.obj_event(2_u64, "claim#2", "claim", %({})),
        ToolSpecHelper.obj_event(3_u64, "claim#3", "claim", %({})),
      ])
      tool = Chronicle.make_graph_query_tool(g)
      output = JSON.parse(tool.call(%({"object_type":"claim","limit":2}))).as_h
      output["refs"].as_a.size.should eq(2)
      output["truncated"].as_bool.should be_true
    end
  end

  describe Chronicle::ToolRegistry do
    it "registers, snapshots, and clears tools" do
      Chronicle::ToolRegistry.clear
      tool = Chronicle::Tool.new("echo", "returns args") { |args| args }
      Chronicle::ToolRegistry.register(tool)
      Chronicle::ToolRegistry.snapshot.map(&.name).should eq(["echo"])
      Chronicle::ToolRegistry.clear
      Chronicle::ToolRegistry.snapshot.should be_empty
    end
  end
end

describe Chronicle::ToolCache do
  it "serves cached tool results during replay" do
    store = Chronicle::MemoryEventStore.new
    cache = Chronicle::ToolCache.from_events([
      Chronicle::Event.new(
        schema_version: 1_u16, sequence: 1_u64, id: "req_1",
        type: "tool.requested", actor: "runtime", caused_by: nil,
        timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
        payload: %({"tool":"search","args":{"q":"test"}}),
      ),
      Chronicle::Event.new(
        schema_version: 1_u16, sequence: 2_u64, id: "resp_1",
        type: "tool.responded", actor: "tool", caused_by: "req_1",
        timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
        payload: %({"tool":"search","args":{"q":"test"},"output":{"results":["a","b"]}}),
      ),
    ])
    cache.get("search", %({"q":"test"})).should_not be_nil
  end
end

describe Chronicle::Runtime do
  it "invokes a registered tool and records tool.requested/responded" do
    store = Chronicle::MemoryEventStore.new
    search = Chronicle::Tool.new("search", "search for things") { |args| %({"results":[#{args}]}) }
    agent = Crig::Agent(ToolCallingModel).new(model: ToolCallingModel.new, preamble: "Use tools.")
    la = Chronicle::LogAgent(ToolCallingModel).new(agent, store: store, max_turns: 2)
    runtime = Chronicle::Runtime(ToolCallingModel).new(store: store, log_agent: la, tools: [search])

    runtime.run("Search for test")

    store.iter_events.any? { |e| e.type == "tool.responded" }.should be_true
    responded = store.iter_events.find { |e| e.type == "tool.responded" }.not_nil!
    JSON.parse(responded.payload).as_h["tool"].as_s.should eq("search")
  end
end
