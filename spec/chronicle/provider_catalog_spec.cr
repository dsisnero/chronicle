require "../spec_helper"

describe Chronicle::ProviderCatalog do
  it "exposes only configured, enabled, credential-eligible policy targets" do
    config = Chronicle::Config.from_yaml(<<-YAML)
    providers:
      ollama:
        type: ollama
        local: true
      anthropic:
        type: anthropic
        api_key_env: CLARITY_MISSING_TEST_KEY
      disabled-openai:
        type: openai
        api_key: test
        disabled: true
    YAML
    policy = Chronicle::Routing::Policy.new(
      default_target: Chronicle::Routing::Target.new("anthropic", "claude-sonnet"),
      default_fallbacks: [
        Chronicle::Routing::Target.new("ollama", "qwen2.5-coder", false),
        Chronicle::Routing::Target.new("disabled-openai", "gpt-5"),
      ],
    )

    catalog = Chronicle::ProviderCatalog.new(config)

    catalog.available_targets(policy).should eq([
      Chronicle::Routing::Target.new("ollama", "qwen2.5-coder", false),
    ])
    catalog.unavailable_reason(Chronicle::Routing::Target.new("anthropic", "claude-sonnet")).should eq("missing credential")
    catalog.unavailable_reason(Chronicle::Routing::Target.new("disabled-openai", "gpt-5")).should eq("provider disabled")
  end
end
