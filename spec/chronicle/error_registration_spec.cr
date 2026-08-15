require "../spec_helper"

# PR-E registration/execution error leaves: MissingProviderError,
# MissingToolError, UnknownToolError. Ported from activegraph llm/errors.py,
# tools/errors.py + test_errors_format.py.

describe Chronicle::MissingProviderError do
  it "is a RegistrationError and formats with the locked structured message" do
    err = Chronicle::MissingProviderError.new(behavior_name: "diligence.researcher")
    err.should be_a(Chronicle::RegistrationError)
    msg = err.to_s
    msg.should contain("MissingProviderError: no LLM provider configured for @llm_behavior")
    msg.should contain("LLM-backed behavior (\"diligence.researcher\")")
    msg.should contain("llm_provider=")
    msg.should contain("RecordedLLMProvider")
    msg.should contain("More:")
    err.context["behavior_name"].as_s.should eq("diligence.researcher")
  end

  it "omits the behavior name when not given" do
    err = Chronicle::MissingProviderError.new
    err.to_s.should contain("An @llm_behavior was registered, but Runtime(...) was constructed without an `llm_provider=` argument.")
    err.context.has_key?("behavior_name").should be_false
  end
end

describe Chronicle::MissingToolError do
  it "is a RegistrationError and enumerates the registered tools" do
    err = Chronicle::MissingToolError.new(
      "web_search",
      behavior_name: "diligence.researcher",
      registered: ["diligence.fetch_company_docs", "diligence.fetch_filings"],
    )
    err.should be_a(Chronicle::RegistrationError)
    msg = err.to_s
    msg.should contain("MissingToolError: no tool named \"web_search\" is registered")
    msg.should contain("@llm_behavior \"diligence.researcher\"")
    msg.should contain("registered tools: 'diligence.fetch_company_docs', 'diligence.fetch_filings'")
    msg.should contain("Runtime(graph, tools=[my_tool, ...])")
    msg.should contain("load_pack")
    err.context["tool_name"].as_s.should eq("web_search")
    err.context["behavior_name"].as_s.should eq("diligence.researcher")
    err.context["registered"].as_a.map(&.as_s).should eq(["diligence.fetch_company_docs", "diligence.fetch_filings"])
  end

  it "shows a (+N more) suffix when more than six tools are registered" do
    names = (1..8).map { |i| "pack.tool#{i}" }
    err = Chronicle::MissingToolError.new("web_search", registered: names)
    err.to_s.should contain("(+2 more)")
  end
end

describe Chronicle::UnknownToolError do
  it "is an ExecutionError and lists the declared tools" do
    err = Chronicle::UnknownToolError.new(
      "LLM called tool 'web_search' which is not declared",
      tool_name: "web_search",
      behavior_name: "diligence.researcher",
      declared_tools: ["diligence.fetch_company_docs", "diligence.fetch_filings"],
    )
    err.should be_a(Chronicle::ExecutionError)
    msg = err.to_s
    msg.should contain("UnknownToolError: LLM called tool 'web_search' which is not declared")
    msg.should contain("tool requested: \"web_search\"")
    msg.should contain("declared on behavior \"diligence.researcher\"")
    msg.should contain("'diligence.fetch_company_docs', 'diligence.fetch_filings'")
    msg.should contain("tools=[...]")
    msg.should contain("replay determinism")
    err.context["message"].as_s.should eq("LLM called tool 'web_search' which is not declared")
    err.context["tool_name"].as_s.should eq("web_search")
    err.context["behavior_name"].as_s.should eq("diligence.researcher")
  end

  it "renders (none declared) when no declared tools are given" do
    err = Chronicle::UnknownToolError.new("no declared")
    err.to_s.should contain("(none declared)")
  end
end
