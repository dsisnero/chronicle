require "../spec_helper"

# Fixture-based tool invokers (CONTRACT v0.7 #15). Mirrors llm/recorded.py:
# fixtures at <dir>/<tool_name>/<args_hash>.json, `recorded_at` outside the
# hash. Recorded mode reads; Recording wraps an inner invoker and persists.

struct ToolAddInput
  include JSON::Serializable

  getter a : Int32
  getter b : Int32
end

private def add_tool : Chronicle::Tool
  Chronicle::Tool.new("add", "add two ints", true) do |args|
    input = JSON.parse(args).as_h
    sum = input["a"].as_i + input["b"].as_i
    %({"sum":#{sum}})
  end
end

private def add_args(a : Int32, b : Int32) : String
  %({"a":#{a},"b":#{b}})
end

private def tool_ctx : Hash(String, JSON::Any)
  {
    "behavior_name"   => JSON::Any.new("b"),
    "event_id"        => JSON::Any.new("evt_1"),
    "idempotency_key" => JSON::Any.new("k"),
  }
end

describe Chronicle::ToolCache do
  describe ".canonicalize_args" do
    it "re-encodes dict args with stable key order" do
      Chronicle::ToolCache.canonicalize_args(%({"b":2,"a":1})).should eq(%({"a":1,"b":2}))
    end

    it "passes scalars through" do
      Chronicle::ToolCache.canonicalize_args("5").should eq("5")
    end
  end

  describe ".hash_tool_call" do
    it "is stable across dict key order (test_hash_tool_call_stable_across_dict_order)" do
      h1 = Chronicle::ToolCache.hash_tool_call("x", %({"a":1,"b":2}))
      h2 = Chronicle::ToolCache.hash_tool_call("x", %({"b":2,"a":1}))
      h1.should eq(h2)
      h1.size.should eq(64)
    end

    it "changes when the tool name changes (test_hash_tool_call_changes_with_name)" do
      h1 = Chronicle::ToolCache.hash_tool_call("x", %({"a":1}))
      h2 = Chronicle::ToolCache.hash_tool_call("y", %({"a":1}))
      h1.should_not eq(h2)
    end
  end
end

describe Chronicle::CachedToolResponse do
  it "exposes output, error, latency, cost, and cache_hit" do
    response = Chronicle::CachedToolResponse.new(
      output: %({"sum":5}),
      error: nil,
      latency_seconds: 0.1,
      cost_usd: "0.001",
    )
    response.output.should eq(%({"sum":5}))
    response.error.should be_nil
    response.latency_seconds.should eq(0.1)
    response.cost_usd.should eq("0.001")
    response.cache_hit?.should be_false
  end
end

describe Chronicle::DirectToolInvoker do
  it "runs the tool body and returns a CachedToolResponse (test_direct_invoker_runs_tool_body)" do
    tool = add_tool
    response = Chronicle::DirectToolInvoker.new.invoke(tool, add_args(1, 2))
    response.output.should eq(%({"sum":3}))
    response.error.should be_nil
    response.cache_hit?.should be_false
  end

  it "traps a tool exception as tool.execution_error (test_direct_invoker_traps_tool_exception)" do
    tool = Chronicle::Tool.new("broken", "throws", false) do |_args|
      raise "boom"
    end
    error = expect_raises(Chronicle::ToolError) do
      Chronicle::DirectToolInvoker.new.invoke(tool, add_args(1, 2))
    end
    error.reason.should eq("tool.execution_error")
  end

  it "propagates an explicit ToolError unchanged (test_direct_invoker_propagates_explicit_tool_error)" do
    tool = Chronicle::Tool.new("timeout_tool", "times out", false) do |_args|
      raise Chronicle::ToolError.new("tool.timeout", "took too long")
    end
    error = expect_raises(Chronicle::ToolError) do
      Chronicle::DirectToolInvoker.new.invoke(tool, add_args(1, 2))
    end
    error.reason.should eq("tool.timeout")
  end
end

describe Chronicle::RecordingToolProvider do
  it "records a fixture then RecordedToolProvider reads it back (test_recording_then_recorded_round_trip)" do
    dir = pack_spec_dir("tool_fixtures_roundtrip")
    tool = add_tool

    rec = Chronicle::RecordingToolProvider.new(Chronicle::DirectToolInvoker.new, dir)
    rec.invoke(tool, add_args(2, 3))

    files = Dir.glob(File.join(dir, "**", "*.json"))
    files.size.should eq(1)

    recorded = Chronicle::RecordedToolProvider.new(dir)
    response = recorded.invoke(tool, add_args(2, 3))
    response.output.should eq(%({"sum":5}))
  end

  it "writes a fixture with recorded_at outside the hashed args" do
    dir = pack_spec_dir("tool_fixtures_recorded_at")
    tool = add_tool
    rec = Chronicle::RecordingToolProvider.new(Chronicle::DirectToolInvoker.new, dir)
    rec.invoke(tool, add_args(2, 3))

    files = Dir.glob(File.join(dir, "**", "*.json"))
    data = JSON.parse(File.read(files.first)).as_h
    data.has_key?("recorded_at").should be_true
    data["recorded_at"].as_s.should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    data["args"].as_h.has_key?("recorded_at").should be_false
    File.basename(files.first).should eq("#{data["args_hash"].as_s}.json")
  end
end

describe Chronicle::RecordedToolProvider do
  it "raises ToolError with reason tool.fixture_missing on a missing fixture (test_recorded_missing_fixture)" do
    dir = pack_spec_dir("tool_fixtures_missing")
    recorded = Chronicle::RecordedToolProvider.new(dir)
    error = expect_raises(Chronicle::ToolError) do
      recorded.invoke(add_tool, add_args(9, 9))
    end
    error.reason.should eq("tool.fixture_missing")
    error.payload_extras.has_key?("args_hash").should be_true
    error.payload_extras.has_key?("tool").should be_true
  end
end
