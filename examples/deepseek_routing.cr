require "../src/chronicle"

# A platform-edge executor that fulfills model EffectRequests via crig.
# In a production system this would be part of CMLPlatformEdge; here it's
# a simple synchronous adapter for the example.
struct ModelEffectExecutor
  getter client : Crig::Providers::DeepSeek::Client

  def initialize(@client : Crig::Providers::DeepSeek::Client)
  end

  # Execute an EffectRequest by calling the DeepSeek API.
  # Returns the response text.
  def execute(target_model : String, prompt_text : String) : String
    model = @client.completion_model(target_model)
    agent = Crig::Agent(Crig::Providers::DeepSeek::CompletionModel).new(
      model: model,
      preamble: "You are a helpful assistant.",
    )
    agent.prompt(prompt_text).send
  end
end

def run_example
  puts "=" * 60
  puts "Chronicle: Deterministic Routing + DeepSeek Integration"
  puts "=" * 60

  # 1. Create DeepSeek client
  api_key = ENV["DEEPSEEK_API_KEY"]?
  unless api_key
    puts "ERROR: DEEPSEEK_API_KEY not set."
    puts "Set it with: export DEEPSEEK_API_KEY=sk-... (or use your mise/sops config)"
    exit 1
  end
  client = Crig::Providers::DeepSeek::Client.new(api_key)

  # 2. Load routing policy
  config_path = File.join(__DIR__, "routing_config.yml")
  policy = Chronicle::Routing::Config.from_file(config_path)
  available = policy.configured_targets

  puts "\nAvailable targets:"
  available.each { |target| puts "  #{target.provider}/#{target.model}#{target.remote? ? " (remote)" : " (local)"}" }

  # 3. Test different intents
  test_cases = [
    {text: "Hello, what can you do?", intent: Chronicle::Routing::Intent::Chat},
    {text: "Review this code for SQL injection vulnerabilities", intent: Chronicle::Routing::Intent::Review},
    {text: "Plan the architecture for a microservice deployment", intent: Chronicle::Routing::Intent::Plan},
  ]

  router = Chronicle::Routing::Router.new
  executor = ModelEffectExecutor.new(client)

  test_cases.each do |test|
    puts "\n#{"-" * 60}"
    puts "Request: \"#{test[:text]}\""
    puts "Intent:  #{test[:intent]}"

    request = Chronicle::Routing::Request.new(
      test[:text],
      test[:intent],
      nil,
      [] of String,
      [] of Chronicle::Routing::ContextCandidate,
      nil,
      50,
    )

    decision = router.preview(request, policy, available)

    puts "\nRouting Decision:"
    puts "  Matched rule: #{decision.matched_rule}"
    puts "  Model:        #{decision.target.provider}/#{decision.target.model}"
    puts "  Reason:       #{decision.routing_reason}"
    puts "  Override:     #{decision.override_used?}"
    puts "  Fallback:     #{decision.fallback_used?}"
    puts "  Intent:       #{decision.intent}"
    puts "  Confidence:   #{(decision.classification.confidence * 100).to_i}%"

    # 4. Execute the model call
    prompt_text = test[:text]
    puts "\nCalling #{decision.target.model}..."
    response = executor.execute(decision.target.model, prompt_text)
    puts "Response: #{response.strip}"
  end

  puts "\n" + "=" * 60
  puts "Done — all routes use different DeepSeek models per intent."
  puts "=" * 60
end

run_example
