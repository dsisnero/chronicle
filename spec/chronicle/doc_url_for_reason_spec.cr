require "../spec_helper"

describe Chronicle::RuntimeReason do
  it "maps llm.* reason codes to the llm-behavior-error page (test_v1_0_3_reason_mapping)" do
    Chronicle::RuntimeReason.doc_url_for_reason("llm.parse_error").should end_with("/errors/llm-behavior-error")
    Chronicle::RuntimeReason.doc_url_for_reason("llm.schema_violation").should end_with("/errors/llm-behavior-error")
  end

  it "maps tool.* reason codes to the tool-error page" do
    Chronicle::RuntimeReason.doc_url_for_reason("tool.unknown_tool").should end_with("/errors/tool-error")
  end

  it "maps budget.* reason codes to the budget-exhausted page" do
    Chronicle::RuntimeReason.doc_url_for_reason("budget.cost_exhausted").should end_with("/errors/budget-exhausted")
  end

  it "defaults to the generic execution-error page for unmatched reasons" do
    Chronicle::RuntimeReason.doc_url_for_reason("exception.RuntimeError").should end_with("/errors/execution-error")
  end

  it "is a full URL rooted at the docs base" do
    Chronicle::RuntimeReason.doc_url_for_reason("tool.timeout").should start_with(Chronicle::DOCS_BASE_URL)
  end
end
