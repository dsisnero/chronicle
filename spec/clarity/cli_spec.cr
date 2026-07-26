require "../spec_helper"

def with_temp_log(content : String, &)
  path = "/tmp/_clarity_cli_test.log"
  File.write(path, content)
  yield path
  File.delete(path)
end

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

  it "inspects a log file and shows event count" do
    header = %({"format":"clarity.event-log","version":1})
    event = %({"schema_version":1,"sequence":1,"id":"evt_000001","type":"goal.created","actor":"user","caused_by":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"test"}})
    log_content = "#{header}\n#{event}\n"

    with_temp_log(log_content) do |path|
      output = Clarity::CLI.run(["log", "inspect", "--file", path])
      output.should contain("Events:    1")
      output.should contain("goal.created")
    end
  end

  it "replays a log file and shows replay results" do
    header = %({"format":"clarity.event-log","version":1})
    event = %({"schema_version":1,"sequence":1,"id":"evt_000001","type":"goal.created","actor":"user","caused_by":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"test"}})
    log_content = "#{header}\n#{event}\n"

    with_temp_log(log_content) do |path|
      output = Clarity::CLI.run(["replay", "--file", path])
      output.should contain("Replay complete")
      output.should_not contain("ERROR")
    end
  end
end
