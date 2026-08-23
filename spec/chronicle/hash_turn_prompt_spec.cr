require "../spec_helper"

private def turn_prompt_params(
  messages : Array(Chronicle::LLMMessage) = [Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi")],
  tools : Array(Hash(String, JSON::Any))? = nil,
  structured_output_mode : String = "prompt",
) : {String, Array(Chronicle::LLMMessage), Int32, Float64, Float64, Bool, Array(Hash(String, JSON::Any))?, String}
  {
    "claude-sonnet-4-5", messages, 512, 0.0, 1.0, true, tools, structured_output_mode,
  }
end

private def hash_turn(model, messages, max_tokens, temperature, top_p, deterministic, tools, mode) : String
  Chronicle::Prompt.hash_turn_prompt(
    model: model,
    system: "sys",
    messages: messages,
    output_schema_json: nil,
    max_tokens: max_tokens,
    temperature: temperature,
    top_p: top_p,
    deterministic: deterministic,
    tools: tools,
    structured_output_mode: mode,
  )
end

describe Chronicle::Prompt do
  describe ".hash_turn_prompt" do
    it "produces a 64-hex SHA-256 key" do
      model, messages, max_tokens, temperature, top_p, deterministic, tools, mode = turn_prompt_params
      hash = hash_turn(model, messages, max_tokens, temperature, top_p, deterministic, tools, mode)
      hash.size.should eq(64)
      hash.should match(/^[0-9a-f]{64}$/)
    end

    it "includes the running messages list so each turn hashes distinctly" do
      params = turn_prompt_params
      turn1 = hash_turn(*params)
      params = turn_prompt_params(
        messages: [
          Chronicle::LLMMessage.new(role: Chronicle::Role::User, content: "hi"),
          Chronicle::LLMMessage.new(role: Chronicle::Role::Assistant, content: "let me check"),
        ]
      )
      turn2 = hash_turn(*params)
      turn1.should_not eq(turn2)
    end

    it "includes tools in the key (a gained/lost tool changes the hash)" do
      params = turn_prompt_params
      with_tools = turn_prompt_params(tools: [{"name" => JSON::Any.new("web_fetch")}])
      hash_turn(*params).should_not eq(hash_turn(*with_tools))
    end

    it "is stable across identical inputs" do
      a = hash_turn(*turn_prompt_params)
      b = hash_turn(*turn_prompt_params)
      a.should eq(b)
    end

    it "includes structured_output_mode only when native (CONTRACT v1.3 #1 #7)" do
      params = turn_prompt_params(structured_output_mode: "prompt")
      native = turn_prompt_params(structured_output_mode: "native")
      hash_turn(*params).should_not eq(hash_turn(*native))
    end

    it "includes deterministic so determinism mode hashes differently (test_deterministic_flag_is_in_prompt_hash)" do
      model, messages, max_tokens, temperature, top_p, _det, tools, mode = turn_prompt_params
      det = hash_turn(model, messages, max_tokens, temperature, top_p, true, tools, mode)
      stoch = hash_turn(model, messages, max_tokens, temperature, top_p, false, tools, mode)
      det.should_not eq(stoch)
    end
  end
end
