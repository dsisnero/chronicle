require "../spec_helper"

describe Clarity::ToolCache do
  it "stores and retrieves tool results by name+args hash" do
    cache = Clarity::ToolCache.new
    cache.record("web_search", %({"q":"clarity"}), %({"result":"found"}))
    cache.size.should eq(1)

    result = cache.get("web_search", %({"q":"clarity"}))
    result.should_not be_nil
    result.not_nil!.should eq(%({"result":"found"}))
  end

  it "returns nil for a cache miss" do
    cache = Clarity::ToolCache.new
    cache.get("nonexistent", "{}").should be_nil
  end

  it "populates from tool.responded events" do
    req = Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "tool_req_001",
      type: "tool.requested", actor: "agent", caused_by: nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"tool":"web_search","args":{"q":"clarity"},"call_id":"call_001"}),
    )
    resp = Clarity::Event.new(
      schema_version: 1_u16, sequence: 2_u64, id: "tool_resp_001",
      type: "tool.responded", actor: "agent", caused_by: "tool_req_001",
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"tool":"web_search","args":{"q":"clarity"},"output":{"result":"found"},"call_id":"call_001"}),
    )

    cache = Clarity::ToolCache.from_events([req, resp])
    cache.size.should eq(1)

    result = cache.get("web_search", %({"q":"clarity"}))
    result.should_not be_nil
  end

  it "skips failed tool responses" do
    resp = Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "tool_err",
      type: "tool.responded", actor: "agent", caused_by: "tool_req",
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"tool":"search","args":{},"error":"timeout","call_id":"call_001"}),
    )
    cache = Clarity::ToolCache.from_events([resp])
    cache.size.should eq(0)
  end
end
