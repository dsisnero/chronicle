require "../spec_helper"

# CONTRACT v1.0.2 #1 — LLM model resolution + cross-provider mismatch
# validation. Ports activegraph.runtime.runtime._resolve_and_validate_llm_models
# (runtime.py #L3936) plus _live._validate_one and
# _live._which_shipped_provider_claims (runtime/_live.py #L80-L173).
#
# (a) default resolution: a behavior with no pinned model resolves to the
#     configured provider's default_model (the protocol's own default is the
#     v1.0.1 hardcoded fallback "claude-sonnet-4-5").
# (b) cross-provider mismatch: an explicit model the configured provider does
#     not recognize, but that ANOTHER shipped provider family claims, is a
#     configuration error surfaced before the first network call.
#
# Divergence from upstream: Chronicle behaviors are immutable (getter model),
# so default resolution is computed and returned, not stamped onto the
# behavior. Shipped Anthropic/OpenAI providers are deferred; the decision
# logic takes an injectable list of ShippedProviderFamily descriptors so it
# is fully testable without real shipped providers.

class ClaimsClaudeOnlyProvider < Chronicle::LLMProvider
  def default_model : String
    "claude-sonnet-4-5"
  end

  def recognizes_model(name : String) : Bool
    name.starts_with?("claude-")
  end

  def complete(
    system : String,
    messages : Array(Chronicle::LLMMessage),
    model : String,
    max_tokens : Int32,
    temperature : Float64,
    top_p : Float64,
    output_schema : T.class,
    timeout_seconds : Float64,
    tools : Array(Hash(String, JSON::Any))? = nil,
    structured_output_mode : String = "prompt",
  ) : Chronicle::LLMResponse forall T
    raise "unused"
  end

  def estimate_cost(input_tokens : Int32, output_tokens : Int32, model : String) : String
    raise "unused"
  end

  def count_tokens(system : String, messages : Array(Chronicle::LLMMessage), model : String) : Int32
    raise "unused"
  end
end

class ClaimsGptFamily < Chronicle::LLMProvider
  def default_model : String
    "gpt-4o"
  end

  def recognizes_model(name : String) : Bool
    name.starts_with?("gpt-") || name.starts_with?("o1") || name.starts_with?("o3")
  end

  def complete(
    system : String,
    messages : Array(Chronicle::LLMMessage),
    model : String,
    max_tokens : Int32,
    temperature : Float64,
    top_p : Float64,
    output_schema : T.class,
    timeout_seconds : Float64,
    tools : Array(Hash(String, JSON::Any))? = nil,
    structured_output_mode : String = "prompt",
  ) : Chronicle::LLMResponse forall T
    raise "unused"
  end

  def estimate_cost(input_tokens : Int32, output_tokens : Int32, model : String) : String
    raise "unused"
  end

  def count_tokens(system : String, messages : Array(Chronicle::LLMMessage), model : String) : Int32
    raise "unused"
  end
end

describe Chronicle::RuntimeReason do
  describe ".resolve_llm_model" do
    it "resolves a nil model to the provider's default_model" do
      resolved = Chronicle::RuntimeReason.resolve_llm_model(nil, ClaimsClaudeOnlyProvider.new)
      resolved.should eq("claude-sonnet-4-5")
    end

    it "returns the provider default when the provider declares a non-fallback default" do
      resolved = Chronicle::RuntimeReason.resolve_llm_model(nil, ClaimsGptFamily.new)
      resolved.should eq("gpt-4o")
    end

    it "passes an explicit model through unchanged when the provider recognizes it" do
      resolved = Chronicle::RuntimeReason.resolve_llm_model("claude-3-5-sonnet", ClaimsClaudeOnlyProvider.new)
      resolved.should eq("claude-3-5-sonnet")
    end
  end

  describe ".which_shipped_provider_claims" do
    provider = ClaimsClaudeOnlyProvider.new
    shipped = [
      Chronicle::ShippedProviderFamily.new("Anthropic", "claude-sonnet-4-5", ClaimsClaudeOnlyProvider) do |name|
        name.starts_with?("claude-")
      end,
      Chronicle::ShippedProviderFamily.new("OpenAI", "gpt-4o", ClaimsGptFamily) do |name|
        name.starts_with?("gpt-") || name.starts_with?("o1") || name.starts_with?("o3")
      end,
    ]

    it "returns the first family that recognizes the name, ignoring the excluded family" do
      claimed = Chronicle::RuntimeReason.which_shipped_provider_claims("gpt-4o", provider, shipped)
      claimed.try(&.name).should eq("OpenAI")
    end

    it "returns nil when the name is already claimed by the configured provider's own family" do
      # claude-* is Anthropic's family AND the configured provider's family,
      # so the Anthropic family is excluded and nothing else claims it.
      claimed = Chronicle::RuntimeReason.which_shipped_provider_claims("claude-3-opus", provider, shipped)
      claimed.should be_nil
    end

    it "returns nil when no shipped family claims the name (permissive default)" do
      claimed = Chronicle::RuntimeReason.which_shipped_provider_claims("mistral-medium", provider, shipped)
      claimed.should be_nil
    end

    it "returns nil when the shipped list is empty" do
      claimed = Chronicle::RuntimeReason.which_shipped_provider_claims("gpt-4o", provider, [] of Chronicle::ShippedProviderFamily)
      claimed.should be_nil
    end
  end

  describe ".validate_and_resolve_llm_model" do
    provider = ClaimsClaudeOnlyProvider.new
    shipped = [
      Chronicle::ShippedProviderFamily.new("OpenAI", "gpt-4o", ClaimsGptFamily) do |name|
        name.starts_with?("gpt-") || name.starts_with?("o1") || name.starts_with?("o3")
      end,
    ]

    it "resolves a nil model to the provider default without validating" do
      resolved = Chronicle::RuntimeReason.validate_and_resolve_llm_model(
        behavior_name: "diligence.claim",
        model: nil,
        provider: provider,
        shipped_providers: shipped,
      )
      resolved.should eq("claude-sonnet-4-5")
    end

    it "passes an explicit model the provider recognizes without raising" do
      resolved = Chronicle::RuntimeReason.validate_and_resolve_llm_model(
        behavior_name: "diligence.claim",
        model: "claude-3-opus",
        provider: provider,
        shipped_providers: shipped,
      )
      resolved.should eq("claude-3-opus")
    end

    it "raises InvalidRuntimeConfiguration when another shipped family claims the model" do
      error = expect_raises(Chronicle::InvalidRuntimeConfiguration) do
        Chronicle::RuntimeReason.validate_and_resolve_llm_model(
          behavior_name: "diligence.claim",
          model: "gpt-4o",
          provider: provider,
          shipped_providers: shipped,
        )
      end
      error.message.to_s.should contain("diligence.claim")
      error.message.to_s.should contain("gpt-4o")
      error.message.to_s.should contain("OpenAI")
    end

    it "passes an explicit model no shipped family claims, even when the provider does not recognize it" do
      resolved = Chronicle::RuntimeReason.validate_and_resolve_llm_model(
        behavior_name: "diligence.claim",
        model: "mistral-medium",
        provider: provider,
        shipped_providers: shipped,
      )
      resolved.should eq("mistral-medium")
    end
  end
end
