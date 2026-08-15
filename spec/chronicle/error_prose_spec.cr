require "../spec_helper"

# Per-reason prose tables for structured error fields (what_failed/why/
# how_to_fix). Ported from activegraph.llm.errors (_LLM_REASON_PROSE +
# fallback) and activegraph.tools.errors (_TOOL_REASON_PROSE + fallback).

describe Chronicle::RuntimeReason do
  it "returns llm.parse_error prose with the interpolated message" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.parse_error", "bad json")
    prose[:what_failed].should eq(
      "The LLM provider returned a response that the framework could not parse as JSON:\n  bad json"
    )
    prose[:why].should contain("structured `output_schema`")
    prose[:how_to_fix].should contain("re-record from a clean run")
  end

  it "returns llm.schema_violation prose" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.schema_violation", "wrong enum")
    prose[:what_failed].should eq(
      "The LLM provider returned valid JSON, but the JSON did not match the behavior's declared `output_schema`:\n  wrong enum"
    )
    prose[:why].should contain("replay determinism")
    prose[:how_to_fix].should contain("`Optional[X]`")
  end

  it "returns llm.fixture_missing prose with re-record steps" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.fixture_missing", "no fixture")
    prose[:what_failed].should contain("no fixture for this prompt")
    prose[:how_to_fix].should contain("Re-record the fixture from a live run")
  end

  it "returns llm.rate_limited prose mentioning the retry recording" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.rate_limited", "429")
    prose[:what_failed].should eq(
      "The LLM provider rejected the request as rate-limited:\n  429"
    )
    prose[:why].should contain("`llm.responded` events with an `error` payload")
  end

  it "returns llm.network_error prose" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.network_error", "conn reset")
    prose[:what_failed].should contain("network error")
    prose[:how_to_fix].should contain("fork-and-replay")
    prose[:how_to_fix].should contain("RecordedLLMProvider")
  end

  it "returns llm.auth_error prose (terminal, CONTRACT v1.3 #3)" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.auth_error", "401")
    prose[:what_failed].should contain("credentials")
    prose[:why].should contain("CONTRACT v1.3 #3")
    prose[:how_to_fix].should contain("ANTHROPIC_API_KEY")
  end

  it "returns llm.request_error prose (terminal, CONTRACT v1.3 #3)" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.request_error", "404 unknown model")
    prose[:what_failed].should contain("invalid")
    prose[:why].should contain("CONTRACT v1.3 #3")
    prose[:how_to_fix].should contain("model family rejects")
  end

  it "falls back for an unknown llm reason code, naming the reason" do
    prose = Chronicle::RuntimeReason.llm_prose("llm.weird", "odd")
    prose[:what_failed].should eq("An @llm_behavior wrapper failed with reason \"llm.weird\":\n  odd")
    prose[:why].should contain("reason=\"llm.weird\"")
    prose[:how_to_fix].should contain("activegraph inspect <store> --tail 50")
  end

  it "returns tool.timeout prose" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.timeout", "slow call")
    prose[:what_failed].should eq(
      "A tool invocation exceeded its declared `timeout_seconds`:\n  slow call"
    )
    prose[:how_to_fix].should contain("tool's `timeout_seconds`")
  end

  it "returns tool.network_error prose" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.network_error", "tls failed")
    prose[:what_failed].should contain("network error")
    prose[:why].should contain("tool.responded event payload")
  end

  it "returns tool.invalid_input prose" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.invalid_input", "bad args")
    prose[:what_failed].should eq(
      "A tool was invoked with arguments that didn't match its input schema:\n  bad args"
    )
    prose[:why].should contain("typed input is the contract")
  end

  it "returns tool.invalid_output prose" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.invalid_output", "bad shape")
    prose[:what_failed].should contain("output schema")
    prose[:why].should contain("audit trail would lie")
  end

  it "returns tool.execution_error prose" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.execution_error", "boom")
    prose[:what_failed].should eq("A tool body raised an exception:\n  boom")
    prose[:why].should contain("payload_extras for diagnosis")
  end

  it "returns tool.fixture_missing prose" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.fixture_missing", "n/a")
    prose[:what_failed].should contain("no fixture for this argument combination")
    prose[:how_to_fix].should contain("Re-record the fixture from a live run")
  end

  it "falls back for an unknown tool reason code, naming the reason" do
    prose = Chronicle::RuntimeReason.tool_prose("tool.weird", "odd")
    prose[:what_failed].should eq("A tool invocation failed with reason \"tool.weird\":\n  odd")
    prose[:why].should contain("reason=\"tool.weird\"")
    prose[:how_to_fix].should contain("activegraph inspect <store> --tail 50")
  end
end

describe Chronicle::LLMBehaviorError do
  it "derives structured fields from the reason prose table" do
    error = Chronicle::LLMBehaviorError.new("llm.parse_error", "bad json")
    error.structured?.should be_true
    error.what_failed.should contain("could not parse as JSON")
    error.why.should contain("output_schema")
    error.context["reason"].as_s.should eq("llm.parse_error")
    error.context["message"].as_s.should eq("bad json")
    error.to_s.should contain("llm.parse_error: bad json")
  end

  it "uses fallback prose for an unlisted reason and preserves reason/message" do
    error = Chronicle::LLMBehaviorError.new("llm.weird", "odd")
    error.structured?.should be_true
    error.what_failed.should contain("reason \"llm.weird\"")
    error.reason.should eq("llm.weird")
    error.payload_extras.should be_empty
  end
end

describe Chronicle::ToolError do
  it "derives structured fields from the reason prose table" do
    error = Chronicle::ToolError.new("tool.timeout", "slow")
    error.structured?.should be_true
    error.what_failed.should contain("timeout_seconds")
    error.context["reason"].as_s.should eq("tool.timeout")
  end

  it "uses fallback prose for an unlisted reason" do
    error = Chronicle::ToolError.new("tool.weird", "odd")
    error.structured?.should be_true
    error.what_failed.should contain("reason \"tool.weird\"")
    error.reason.should eq("tool.weird")
  end
end
