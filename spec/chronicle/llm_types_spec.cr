require "../spec_helper"

describe Chronicle::LLMMessage do
  it "serializes a user message to its wire form" do
    msg = Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hello")
    msg.to_json.should eq(%({"role":"user","content":"hello"}))
  end

  it "omits nil tool fields (byte-identical single-turn fixtures)" do
    msg = Chronicle::LLMMessage.new(role: Chronicle::Role::Assistant, content: "ok")
    msg.to_json.should eq(%({"role":"assistant","content":"ok"}))
  end

  it "round-trips role/content through from_json" do
    msg = Chronicle::LLMMessage.from_json(%({"role":"tool","content":"result"}))
    msg.role.should eq(Chronicle::Role::Tool)
    msg.content.should eq("result")
  end

  it "serializes tool_use_id, tool_name, and tool_calls when present" do
    call = Chronicle::ToolCall.new(
      "call_1",
      "lookup",
      {"q" => JSON::Any.new("x")},
    )
    msg = Chronicle::LLMMessage.new(
      role: Chronicle::Role::Assistant,
      content: "calling",
      tool_use_id: "call_1",
      tool_name: "lookup",
      tool_calls: [call],
    )
    json = msg.to_json
    json.should contain(%("tool_use_id":"call_1"))
    json.should contain(%("tool_name":"lookup"))
    json.should contain(%("tool_calls"))
  end
end

describe Chronicle::LLMResponse do
  it "serializes a normalized provider result" do
    resp = Chronicle::LLMResponse.new(
      raw_text: "fine",
      parsed: nil,
      input_tokens: 10,
      output_tokens: 5,
      cost_usd: "0.001",
      latency_seconds: 0.5,
      model: "m",
      finish_reason: "stop",
    )
    json = resp.to_json
    json.should contain(%("raw_text":"fine"))
    json.should contain(%("input_tokens":10))
    json.should contain(%("cache_hit":false))
  end

  it "serializes tool_calls and provider_meta when present" do
    call = Chronicle::ToolCall.new("call_9", "search", {"k" => JSON::Any.new("v")})
    resp = Chronicle::LLMResponse.new(
      raw_text: "",
      parsed: JSON.parse(%({"n":1})),
      input_tokens: 1,
      output_tokens: 1,
      cost_usd: "0",
      latency_seconds: 0.1,
      model: "m",
      finish_reason: "tool_calls",
      cache_hit: true,
      provider_meta: {"region" => JSON::Any.new("us-east")},
      tool_calls: [call],
    )
    json = resp.to_json
    json.should contain(%("cache_hit":true))
    json.should contain(%("tool_calls"))
    json.should contain(%("provider_meta"))
  end
end
