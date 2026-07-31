require "../spec_helper"

describe Chronicle::Config do
  it "has sensible defaults" do
    config = Chronicle::Config.new
    config.data_dir.should eq("")
    config.providers.should be_empty
  end

  it "loads provider config from YAML" do
    yaml = <<-YAML
    data_dir: ""
    providers:
      deepseek:
        api_key: sk-test
        disabled: false
    debug: false
    YAML

    config = Chronicle::Config.from_yaml(yaml)
    config.providers["deepseek"].api_key.should eq("sk-test")
    config.providers["deepseek"].type.should eq("deepseek")
  end

  it "keeps a named provider instance separate from its provider kind" do
    config = Chronicle::Config.from_yaml(<<-YAML)
    providers:
      "openai-compat:local-vllm":
        type: openai_compatible
        base_url: http://127.0.0.1:8000/v1
        local: true
      anthropic:
        type: anthropic
        api_key_env: CLARITY_TEST_ANTHROPIC_KEY
    YAML

    local = config.providers["openai-compat:local-vllm"]
    local.type.should eq("openai_compatible")
    local.local?.should be_true
    local.base_url.should eq("http://127.0.0.1:8000/v1")

    cloud = config.providers["anthropic"]
    cloud.type.should eq("anthropic")
    cloud.api_key_env.should eq("CLARITY_TEST_ANTHROPIC_KEY")
  end

  it "resolves a configured credential at the platform edge but permits local keyless providers" do
    old_val = ENV["CLARITY_TEST_PROVIDER_KEY"]?
    ENV["CLARITY_TEST_PROVIDER_KEY"] = "test-key"

    config = Chronicle::Config.from_yaml(<<-YAML)
    providers:
      ollama:
        type: ollama
        local: true
      openai:
        type: openai
        api_key_env: CLARITY_TEST_PROVIDER_KEY
    YAML

    config.providers["ollama"].credential_available?.should be_true
    config.providers["openai"].resolved_api_key.should eq("test-key")

    ENV["CLARITY_TEST_PROVIDER_KEY"] = old_val
  end

  it "loads from a YAML file" do
    path = "/tmp/_clarity_config_test.yml"
    File.write(path, "data_dir: /tmp/custom\nproviders:\n")

    config = Chronicle::Config.from_file(path)
    config.data_dir.should eq("/tmp/custom")
    File.delete(path)
  end

  it "merges local config over global" do
    global = Chronicle::Config.from_yaml("data_dir: global\ndebug: true\nproviders:")
    local = Chronicle::Config.from_yaml("data_dir: local\ndebug: false\nproviders:")

    merged = Chronicle::Config.merge(global, local)
    merged.debug?.should be_false
  end

  it "reads provider API key from environment" do
    old_val = ENV["CLARITY_DEEPSEEK_API_KEY"]?
    ENV["CLARITY_DEEPSEEK_API_KEY"] = "env-key-test"

    config = Chronicle::Config.new
    result = config.apply_env_overrides
    result.providers["deepseek"].api_key.should eq("env-key-test")

    ENV["CLARITY_DEEPSEEK_API_KEY"] = old_val
  end

  it "loads from default with env overrides" do
    old_val = ENV["CLARITY_DEBUG"]?
    ENV["CLARITY_DEBUG"] = "true"

    config = Chronicle::Config.load
    config.debug?.should be_true

    ENV["CLARITY_DEBUG"] = old_val
  end
end
