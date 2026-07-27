require "crig"

module Clarity
  # Platform-edge construction contract for a Crig provider family. The
  # instance ID selects endpoint/credentials; `ProviderConfig#type` selects
  # this factory. Neither fact is inferred from a model name.
  abstract class CrigProviderFactory
    abstract def build(
      instance_id : String,
      config : ProviderConfig,
      target : Routing::Target,
    ) : ModelExecutor

    protected def required_api_key(instance_id : String, config : ProviderConfig) : String
      config.resolved_api_key || raise ProviderNotAvailableError.new("missing credential for #{instance_id}")
    end
  end

  # Platform-edge boundary for invoking the model chosen by a route receipt.
  # Implementations own provider credentials and network I/O; Runtime does not.
  abstract class ModelExecutor
    abstract def completion(
      target : Routing::Target?,
      request : Crig::Completion::Request::CompletionRequest,
    ) : Crig::Completion::CompletionResponse(String)
  end

  # Ephemeral platform-edge input: the durable request contract plus the Crig
  # request assembled from the recorded turn. It is never persisted.
  struct ModelEffectInvocation
    getter effect : ModelEffectRequest
    getter request : Crig::Completion::Request::CompletionRequest

    def initialize(@effect : ModelEffectRequest, @request : Crig::Completion::Request::CompletionRequest)
    end
  end

  # Owns live provider invocation at the platform edge and returns only a
  # normalized result to the runtime.
  class ModelEffectWorker
    def initialize(@executor : ModelExecutor)
    end

    def execute(invocation : ModelEffectInvocation) : ModelEffectResult
      response = @executor.completion(invocation.effect.target, invocation.request)
      ModelEffectResult.new(
        invocation.effect.request_event_id,
        invocation.effect.target.provider,
        invocation.effect.target.model,
        response.choice.first.text.try(&.text) || "",
        response.usage.input_tokens.to_i32,
        response.usage.output_tokens.to_i32,
        response.message_id || "",
        response.choice,
      )
    end
  end

  # Adapts one configured provider model to the platform-edge executor
  # contract. ProviderRegistry determines whether this model is eligible for a
  # particular route target before it is invoked.
  class FixedModelExecutor(M) < ModelExecutor
    def initialize(@model : M)
    end

    def completion(
      target : Routing::Target?,
      request : Crig::Completion::Request::CompletionRequest,
    ) : Crig::Completion::CompletionResponse(String)
      response = @model.completion(request)
      Crig::Completion::CompletionResponse(String).new(
        response.choice,
        response.usage,
        "",
        response.message_id,
      )
    end
  end

  # Keyless local Crig adapter. Construction performs no network I/O; the
  # resulting executor performs the request only when the platform edge calls
  # it after a durable model-request event.
  class OllamaProviderFactory < CrigProviderFactory
    def build(
      instance_id : String,
      config : ProviderConfig,
      target : Routing::Target,
    ) : ModelExecutor
      client = Crig::Providers::Ollama::Client.new(
        Crig::Nothing.new,
        config.base_url || Crig::Providers::Ollama::OLLAMA_API_BASE_URL,
      )
      FixedModelExecutor(Crig::Providers::Ollama::CompletionModel).new(client.completion_model(target.model))
    end
  end

  class DeepSeekProviderFactory < CrigProviderFactory
    def build(instance_id : String, config : ProviderConfig, target : Routing::Target) : ModelExecutor
      client = Crig::Providers::DeepSeek::Client.new(required_api_key(instance_id, config), config.base_url || Crig::Providers::DeepSeek::DEEPSEEK_API_BASE_URL)
      FixedModelExecutor(Crig::Providers::DeepSeek::CompletionModel).new(client.completion_model(target.model))
    end
  end

  class OpenAIProviderFactory < CrigProviderFactory
    def build(instance_id : String, config : ProviderConfig, target : Routing::Target) : ModelExecutor
      client = Crig::Providers::OpenAI::Client.new(required_api_key(instance_id, config), config.base_url || Crig::Providers::OpenAI::OPENAI_API_BASE_URL)
      FixedModelExecutor(Crig::Providers::OpenAI::CompletionModel).new(client.completions_api.completion_model(target.model))
    end
  end

  # A named OpenAI-compatible endpoint has independent configuration and
  # identity, but uses the same wire protocol adapter as OpenAI.
  class OpenAICompatibleProviderFactory < OpenAIProviderFactory
  end

  class AnthropicProviderFactory < CrigProviderFactory
    def build(instance_id : String, config : ProviderConfig, target : Routing::Target) : ModelExecutor
      client = Crig::Providers::Anthropic::Client.new(required_api_key(instance_id, config), config.base_url || Crig::Providers::Anthropic::ANTHROPIC_API_BASE_URL)
      FixedModelExecutor(Crig::Providers::Anthropic::CompletionModel).new(client.completion_model(target.model))
    end
  end

  class GeminiProviderFactory < CrigProviderFactory
    def build(instance_id : String, config : ProviderConfig, target : Routing::Target) : ModelExecutor
      client = Crig::Providers::Gemini::Client.new(required_api_key(instance_id, config), config.base_url || Crig::Providers::Gemini::GEMINI_API_BASE_URL)
      FixedModelExecutor(Crig::Providers::Gemini::CompletionModel).new(client.completion_model(target.model))
    end
  end

  module ProviderFactories
    extend self

    def defaults : Hash(String, CrigProviderFactory)
      {
        "ollama"            => OllamaProviderFactory.new.as(CrigProviderFactory),
        "deepseek"          => DeepSeekProviderFactory.new.as(CrigProviderFactory),
        "openai"            => OpenAIProviderFactory.new.as(CrigProviderFactory),
        "openai_compatible" => OpenAICompatibleProviderFactory.new.as(CrigProviderFactory),
        "anthropic"         => AnthropicProviderFactory.new.as(CrigProviderFactory),
        "gemini"            => GeminiProviderFactory.new.as(CrigProviderFactory),
      }
    end
  end

  # Exact target-to-executor mapping owned by the platform edge. It prevents a
  # route receipt from being silently executed by an unrelated default model.
  class ProviderRegistry < ModelExecutor
    def initialize
      @executors = {} of String => ModelExecutor
    end

    def register(target : Routing::Target, executor : ModelExecutor) : self
      @executors[key(target)] = executor
      self
    end

    def registered?(target : Routing::Target) : Bool
      @executors.has_key?(key(target))
    end

    # Builds the executable registry from the availability-filtered provider
    # configuration. An unsupported or ineligible target is deliberately left
    # unregistered, so it cannot be accidentally executed by another factory.
    def self.from_config(
      config : Config,
      targets : Array(Routing::Target),
      factories : Hash(String, CrigProviderFactory),
    ) : self
      registry = new
      catalog = ProviderCatalog.new(config)

      targets.each do |target|
        next unless catalog.available?(target)
        provider = config.providers[target.provider]? || next
        factory = factories[provider.type]? || next
        registry.register(target, factory.build(target.provider, provider, target))
      end

      registry
    end

    def completion(
      target : Routing::Target?,
      request : Crig::Completion::Request::CompletionRequest,
    ) : Crig::Completion::CompletionResponse(String)
      selected = target || raise ProviderNotAvailableError.new("route receipt did not select a provider")
      executor = @executors[key(selected)]? || raise ProviderNotAvailableError.new("no executor registered for #{selected.provider}/#{selected.model}")
      executor.completion(selected, request)
    end

    private def key(target : Routing::Target) : String
      "#{target.provider}/#{target.model}"
    end
  end
end
