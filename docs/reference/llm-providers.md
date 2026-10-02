# LLM providers

Chronicle intentionally does **not** ship direct Anthropic/OpenAI client
classes. Provider execution is a platform-edge concern: the runtime
records a `routing.decided` receipt and a model-request event, and the
host executes the recorded target through the Crig
`ModelExecutor` / `ProviderRegistry` seam. A runtime swapping one
provider for another does not reshape any call site.

```crystal
require "chronicle"
require "crig"

# The platform edge builds one executor per configured, eligible target.
registry = Chronicle::ProviderRegistry.from_config(
  config, available_targets, Chronicle::ProviderFactories.defaults,
)
worker = Chronicle::ModelEffectWorker.new(registry)

runtime = Chronicle::Runtime(MyModel).new(
  store: store, log_agent: log_agent, graph: graph,
  policy: policy, available_targets: available_targets,
  model_effect_worker: worker,
)
```

The router (not a client) owns deterministic classification, policy
enforcement, provider/model selection, and ordered fallback selection.
`Chronicle::Routing::Target` names the chosen `provider`/`model`;
`Chronicle::ProviderCatalog` is the platform-edge availability snapshot.

## Installing / configuring

Providers are configured through `shard.yml` (the Crig shards) plus
`Chronicle::Config` (`~/.chronicle/config.yml` or `.chronicle.yml`).
Each configured instance has a stable key (the name routes reference)
and a `type` selecting its factory:

| `ProviderConfig#type` | Factory |
| --- | --- |
| `ollama` | `Chronicle::OllamaProviderFactory` |
| `deepseek` | `Chronicle::DeepSeekProviderFactory` |
| `openai` | `Chronicle::OpenAIProviderFactory` |
| `openai_compatible` | `Chronicle::OpenAICompatibleProviderFactory` |
| `anthropic` | `Chronicle::AnthropicProviderFactory` |
| `gemini` | `Chronicle::GeminiProviderFactory` |

## API keys

Credentials are resolved at the edge and never enter the event log or the
core. `ProviderConfig` accepts an explicit `api_key` or an
`api_key_env`; `Config.env_overrides` also reads the namespaced
`CLARITY_*` variables before the bare ones:

```bash
export CLARITY_DEEPSEEK_API_KEY='...'   # or DEEPSEEK_API_KEY
export CLARITY_OPENAI_API_KEY='...'     # or OPENAI_API_KEY
export CLARITY_ANTHROPIC_API_KEY='...'  # or ANTHROPIC_API_KEY
```

`ProviderCatalog#available?` reports a provider as unavailable when it is
unconfigured, disabled, or missing a credential
(`unavailable_reason(target)`).

## Default model resolution

Each `@[LLMBehavior]` defaults `model` to `"claude-sonnet-4-5"` when it
does not pin one. In a routed run the effective model comes from the
selected `Routing::Target`, so swapping a routing policy is the way to
change the default model family:

```crystal
@[LLMBehavior(name: "extractor", output_schema: Claim)]
def self.extractor(event, graph, ctx, output : Claim) : Nil
  # ...
end
```

Pass `model:` on the annotation to pin an explicit name.

## Cross-provider model-name validation

When a behavior pins `model="..."` explicitly, the runtime validates the
name at registration/binding time. Chronicle exposes the pure logic as
`Chronicle::RuntimeReason.validate_and_resolve_llm_model` /
`which_shipped_provider_claims`, backed by `Chronicle::ShippedProviderFamily`
descriptors. A recognized cross-provider mismatch raises
`Chronicle::InvalidRuntimeConfiguration` naming both providers, before the
first network call. Names no shipped descriptor recognizes pass through
silently.

> Divergence: upstream validates against concrete `AnthropicProvider` /
> `OpenAIProvider` `recognizes_model()` methods. Chronicle's
> `ShippedProviderFamily` keeps the decision logic testable without those
> client classes. See [`plans/parity.md`](../../plans/parity.md).

## Side-by-side

| Aspect | `AnthropicProviderFactory` | `OpenAIProviderFactory` |
| --- | --- | --- |
| Underlying adapter | Crig `Providers::Anthropic::Client` | Crig `Providers::OpenAI::Client` |
| Credential | `config.resolved_api_key` (env/`ProviderConfig`) | same |
| Base URL override | `config.base_url` | `config.base_url` |
| Target selection | `Routing::Target(provider, model)` | same |
| Execution | `FixedModelExecutor(Crig::...::CompletionModel)` | same |
| Structured output | prompt-embedded by default; native mode via `native_structured_output:` | same |

## Native structured output (opt-in)

`Runtime(native_structured_output: true)` resolves a structured-output
mode per behavior at registration time: native constrained decoding when
the provider supports it for the resolved model **and** the behavior's
`output_schema` fits the native subset (every field required, no
numeric/string constraint keywords, no recursion); the prompt-embedded
path otherwise. Nothing changes at the `@[LLMBehavior]` surface — the
schema stays `output_schema=`.

`Chronicle::Native` ports the schema pre-flight
(`native_schema_compatible`, `inject_additional_properties_false`) and
the pure `resolve_structured_output_mode(flag, model, capability, schema)`
resolver; the runtime takes `native_capability:` as an injectable
provider-capability predicate.

Things to know before flipping the flag:

- **Prompt hashes change.** Native mode contributes to the hash only when
  native, so prompt-mode payloads stay byte-identical and a record-vs-
  replay mode drift surfaces as a cache miss / `ReplayDivergenceError`.
- **Fallback is silent but audited.** The resolved mode rides every
  `llm.requested` event's `structured_output_mode` payload field.
- **Validation doesn't move.** Responses still flow through
  `Chronicle::StructuredOutput`, so `llm.parse_error` /
  `llm.schema_violation` semantics are identical in both modes.

`RecordedLLMProvider` replays whatever mode the fixture was recorded in —
construct it with `structured_output_mode: "native"` to serve native-mode
fixtures (the default `"prompt"` keeps every pre-native fixture reachable).

## Embedding providers

`EmbeddingProvider` is the runtime's second provider seam, next to
`LLMProvider`. Calls go through `Runtime#embed` or the pack-facing
`ctx.embed` so external I/O is recorded and replayable:

```crystal
class MyEmbedder < Chronicle::EmbeddingProvider
  def default_model : String
    "text-embedding-3-small"
  end

  def embed(texts : Array(String), model : String) : Array(Array(Float64))
    # call your embedding API
  end
end

runtime = Chronicle::Runtime(MyModel).new(
  store: store, log_agent: log_agent, graph: graph,
  embedding_provider: MyEmbedder.new,
)
vectors = runtime.embed(["first document", "second document"])
```

Forks inherit the parent's embedding provider; `Runtime.load(...,
embedding_provider: ...)` wires one at load time. Set
`replay_embedding_cache: true` on load/fork to hydrate
`Chronicle::EmbeddingCache` from recorded `embedding.responded` events.
Strict replay enables the cache automatically, verifies the request-hash
sequence, and never calls the provider.

`embedding.requested` records the model and a content hash, not the
source text. `embedding.responded` records validated ordered vectors.

The runtime ships two implementations:
`Chronicle::HashEmbeddingProvider`, a deterministic, dependency-free test
double (token-hash buckets, L2-normalized; also implements Crig's
`EmbeddingModel` seam), and `Chronicle::CrigEmbeddingProvider(M)`, which
adapts any Crig embedding model to the protocol. Real embedding
providers are deliberately not shipped: no network dependencies, no API
keys.

## Mixing with `RecordedLLMProvider`

The fixture-backed provider is provider-agnostic: fixtures are keyed by
prompt-content hash, and the model name is part of the hash input.
Fixtures recorded against one provider replay against
`RecordedLLMProvider` regardless of which live provider you switch to
next.

```crystal
inner = MyLiveProvider.new
provider = Chronicle::RecordingLLMProvider.new(inner, fixtures_dir: "tests/fixtures/llm")
```

`RecordingLLMProvider` wraps either concrete provider the same way.
Record once against a live key, commit the fixtures, run tests against
`RecordedLLMProvider` thereafter. Missing fixtures raise
`LLMBehaviorError` (`llm.fixture_missing`).

## Writing a custom provider

`Chronicle::LLMProvider` is an abstract class. A subclass implements the
three core methods plus the two optional declarations:

```crystal
class MyProvider < Chronicle::LLMProvider
  def default_model : String
    "my-model-name"   # used when @[LLMBehavior] omits model:
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
    # ...
  end

  def estimate_cost(
    input_tokens : Int32, output_tokens : Int32, model : String,
  ) : String
    # USD as a String
  end

  def count_tokens(
    system : String, messages : Array(Chronicle::LLMMessage), model : String,
  ) : Int32
    # ...
  end

  def recognizes_model(name : String) : Bool
    name.starts_with?("my-")
  end

  def supports_native_structured_output(model : String) : Bool
    false
  end
end
```

`default_model`, `recognizes_model`, and
`supports_native_structured_output` are additive and have base-class
defaults. Providers that expose the instruction-based structured-output
path should reuse `Chronicle::StructuredOutput.parse` for identical
`llm.parse_error` / `llm.schema_violation` reason codes.

> Divergence: upstream's `LLMProvider` is a `runtime_checkable` Protocol;
> Chronicle uses an abstract class. The runtime's live execution path uses
> the Crig seam, not this protocol — `LLMProvider` remains the standalone
> recorded-fixture seam.
