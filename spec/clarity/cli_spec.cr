require "../spec_helper"

describe Clarity::CLI do
  it "prints a route preview for a given text and intent" do
    config_path = File.join(__DIR__, "..", "..", "examples", "routing_config.yml")
    args = ["route", "preview", "--config", config_path, "--text", "deploy the microservice", "--intent", "Plan"]

    output = Clarity::CLI.run(args)
    output.should contain("Route Decision")
    output.should contain("Intent:     Plan")
    output.should contain("deepseek-v4-flash")
    output.should_not contain("ERROR")
  end

  it "prints an error when the config file is missing" do
    args = ["route", "preview", "--config", "/nonexistent.yml", "--text", "hello"]
    output = Clarity::CLI.run(args)
    output.should contain("ERROR")
  end
end
