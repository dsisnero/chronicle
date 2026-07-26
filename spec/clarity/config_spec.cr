require "../spec_helper"

describe Clarity::Config do
  it "has sensible defaults" do
    config = Clarity::Config.new
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

    config = Clarity::Config.from_yaml(yaml)
    config.providers["deepseek"].api_key.should eq("sk-test")
  end

  it "loads from a YAML file" do
    path = "/tmp/_clarity_config_test.yml"
    File.write(path, "data_dir: /tmp/custom\nproviders:\n")

    config = Clarity::Config.from_file(path)
    config.data_dir.should eq("/tmp/custom")
    File.delete(path)
  end

  it "merges local config over global" do
    global = Clarity::Config.from_yaml("data_dir: global\ndebug: true\nproviders:")
    local = Clarity::Config.from_yaml("data_dir: local\ndebug: false\nproviders:")

    merged = Clarity::Config.merge(global, local)
    merged.debug?.should be_false
  end

  it "reads provider API key from environment" do
    old_val = ENV["CLARITY_DEEPSEEK_API_KEY"]?
    ENV["CLARITY_DEEPSEEK_API_KEY"] = "env-key-test"

    config = Clarity::Config.new
    result = config.apply_env_overrides
    result.providers["deepseek"].api_key.should eq("env-key-test")

    ENV["CLARITY_DEEPSEEK_API_KEY"] = old_val
  end

  it "loads from default with env overrides" do
    old_val = ENV["CLARITY_DEBUG"]?
    ENV["CLARITY_DEBUG"] = "true"

    config = Clarity::Config.load
    config.debug?.should be_true

    ENV["CLARITY_DEBUG"] = old_val
  end
end
