require "../spec_helper"

private class FixedExecutorSpecModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Executor response")
      ),
      Crig::Completion::Usage.new,
      "raw",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    ["Executor response"]
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

private class RecordingProviderFactory < Clarity::CrigProviderFactory
  getter calls = [] of {String, String, String}

  def initialize(@executor : Clarity::ModelExecutor)
  end

  def build(instance_id : String, config : Clarity::ProviderConfig, target : Clarity::Routing::Target) : Clarity::ModelExecutor
    @calls << {instance_id, config.type, target.model}
    @executor
  end
end

describe Clarity::FixedModelExecutor do
  it "executes the registered model for its target" do
    model = FixedExecutorSpecModel.new
    target = Clarity::Routing::Target.new("deepseek", "deepseek-v4-flash")
    executor = Clarity::FixedModelExecutor(FixedExecutorSpecModel).new(model)
    request = model.completion_request("Hello").build

    response = executor.completion(target, request)

    response.choice.first.text.not_nil!.text.should eq("Executor response")
  end
end

describe Clarity::ProviderRegistry do
  it "builds an exact target registry through the configured provider kind" do
    config = Clarity::Config.from_yaml(<<-YAML)
    providers:
      ollama:
        type: ollama
        local: true
      "openai-compat:lab":
        type: openai_compatible
        base_url: http://127.0.0.1:8000/v1
        local: true
    YAML
    ollama_target = Clarity::Routing::Target.new("ollama", "qwen2.5-coder", false)
    compat_target = Clarity::Routing::Target.new("openai-compat:lab", "llama-3.1", false)
    executor = Clarity::FixedModelExecutor(FixedExecutorSpecModel).new(FixedExecutorSpecModel.new)
    ollama_factory = RecordingProviderFactory.new(executor)
    compat_factory = RecordingProviderFactory.new(executor)

    registry = Clarity::ProviderRegistry.from_config(
      config,
      [ollama_target, compat_target],
      {"ollama" => ollama_factory.as(Clarity::CrigProviderFactory), "openai_compatible" => compat_factory.as(Clarity::CrigProviderFactory)},
    )

    registry.registered?(ollama_target).should be_true
    registry.registered?(compat_target).should be_true
    ollama_factory.calls.should eq([{"ollama", "ollama", "qwen2.5-coder"}])
    compat_factory.calls.should eq([{"openai-compat:lab", "openai_compatible", "llama-3.1"}])
  end

  it "does not substitute a different factory for an unsupported provider kind" do
    config = Clarity::Config.from_yaml(<<-YAML)
    providers:
      gemini:
        type: gemini
        api_key: test
    YAML
    target = Clarity::Routing::Target.new("gemini", "gemini-2.5-flash")
    executor = Clarity::FixedModelExecutor(FixedExecutorSpecModel).new(FixedExecutorSpecModel.new)
    wrong_factory = RecordingProviderFactory.new(executor)

    registry = Clarity::ProviderRegistry.from_config(
      config,
      [target],
      {"ollama" => wrong_factory.as(Clarity::CrigProviderFactory)},
    )

    registry.registered?(target).should be_false
    wrong_factory.calls.should be_empty
  end

  it "constructs a keyless local Ollama executor without contacting the endpoint" do
    config = Clarity::Config.from_yaml(<<-YAML)
    providers:
      ollama:
        type: ollama
        base_url: http://127.0.0.1:11434
        local: true
    YAML
    target = Clarity::Routing::Target.new("ollama", "qwen2.5-coder", false)

    registry = Clarity::ProviderRegistry.from_config(
      config,
      [target],
      {"ollama" => Clarity::OllamaProviderFactory.new.as(Clarity::CrigProviderFactory)},
    )

    registry.registered?(target).should be_true
  end

  it "constructs cloud Crig executors from configured credentials without network I/O" do
    config = Clarity::Config.from_yaml(<<-YAML)
    providers:
      deepseek: {type: deepseek, api_key: deepseek-test}
      openai: {type: openai, api_key: openai-test}
      anthropic: {type: anthropic, api_key: anthropic-test}
      gemini: {type: gemini, api_key: gemini-test}
    YAML
    targets = [
      Clarity::Routing::Target.new("deepseek", "deepseek-chat"),
      Clarity::Routing::Target.new("openai", "gpt-4o"),
      Clarity::Routing::Target.new("anthropic", "claude-sonnet"),
      Clarity::Routing::Target.new("gemini", "gemini-2.5-flash"),
    ]

    registry = Clarity::ProviderRegistry.from_config(config, targets, Clarity::ProviderFactories.defaults)

    targets.each { |target| registry.registered?(target).should be_true }
  end

  it "uses a named OpenAI-compatible instance rather than the built-in OpenAI instance" do
    config = Clarity::Config.from_yaml(<<-YAML)
    providers:
      "openai-compat:lab":
        type: openai_compatible
        api_key: local-gateway-key
        base_url: http://127.0.0.1:8000/v1
        local: true
    YAML
    target = Clarity::Routing::Target.new("openai-compat:lab", "llama-3.1-70b", false)

    registry = Clarity::ProviderRegistry.from_config(config, [target], Clarity::ProviderFactories.defaults)

    registry.registered?(target).should be_true
  end
end
