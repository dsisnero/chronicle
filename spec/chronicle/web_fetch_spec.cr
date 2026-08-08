require "../spec_helper"

# `web_fetch` reference tool (CONTRACT v0.7 #16, v1.8 #7): a non-deterministic
# external-IO tool that fails closed — it refuses to run unless the caller
# explicitly allows live-unrecorded external I/O, before any network contact.
# The input/output are typed value structs. Ported from
# activegraph.tools.web_fetch + test_web_fetch_hardening.

describe Chronicle do
  it "web_fetch tool is non-deterministic and fails closed on forbid" do
    tool = Chronicle.make_web_fetch_tool
    tool.deterministic?.should be_false

    expect_raises(Chronicle::ToolError) do
      tool.call(%({"url":"https://example.test"}), Chronicle::ExternalIOMode::Forbid)
    end
  end

  it "web_fetch tool fails closed on runtime_recorded without a recorded hook" do
    tool = Chronicle.make_web_fetch_tool
    expect_raises(Chronicle::ToolError) do
      tool.call(%({"url":"https://example.test"}), Chronicle::ExternalIOMode::RuntimeRecorded)
    end
  end

  it "web_fetch tool performs an unrecorded fetch under live_unrecorded" do
    tool = Chronicle.make_web_fetch_tool(fetcher: ->(url : String) {
      Chronicle::WebFetchOutput.new("ok", 200, url)
    })
    output = tool.call(%({"url":"https://example.test"}), Chronicle::ExternalIOMode::LiveUnrecorded)
    parsed = JSON.parse(output).as_h
    parsed["text"].as_s.should eq("ok")
    parsed["status"].as_i.should eq(200)
  end
end
