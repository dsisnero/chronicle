require "../spec_helper"

def with_temp_log(content : String, &)
  path = "/tmp/_clarity_cli_test.log"
  File.write(path, content)
  yield path
  File.delete(path)
end

private def cli_log(header : String, events : Array(String)) : String
  "#{header}\n#{events.join("\n")}\n"
end

private def cli_obj_event(seq : UInt64, id : String, type : String = "object.created") : String
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: seq, id: id,
    type: type, actor: "test", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: %({"id":"#{id}","type":"doc","data":{"text":"#{id}"}}),
  ).canonical_json
end

describe Chronicle::CLI do
  it "prints a route preview for a given text and intent" do
    config_path = File.join(__DIR__, "..", "..", "examples", "routing_config.yml")
    args = ["route", "preview", "--config", config_path, "--text", "deploy the microservice", "--intent", "Plan"]

    output = Chronicle::CLI.run(args)
    output.should contain("Route Decision")
    output.should contain("Intent:     Plan")
    output.should contain("deepseek-v4-flash")
    output.should_not contain("ERROR")
  end

  it "prints an error when the config file is missing" do
    args = ["route", "preview", "--config", "/nonexistent.yml", "--text", "hello"]
    output = Chronicle::CLI.run(args)
    output.should contain("ERROR")
  end

  it "inspects a log file and shows event count" do
    header = %({"format":"chronicle.event-log","version":1})
    event = %({"schema_version":1,"sequence":1,"id":"evt_000001","type":"goal.created","actor":"user","caused_by":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"test"}})
    log_content = "#{header}\n#{event}\n"

    with_temp_log(log_content) do |path|
      output = Chronicle::CLI.run(["log", "inspect", "--file", path])
      output.should contain("Events:    1")
      output.should contain("goal.created")
    end
  end

  it "log inspect renders frame_id on events that carry one" do
    header = %({"format":"chronicle.event-log","version":1})
    goal = %({"schema_version":1,"sequence":1,"id":"goal_1","type":"goal.created","actor":"user","caused_by":null,"frame_id":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"ship"}})
    framed = %({"schema_version":1,"sequence":2,"id":"evt_2","type":"object.created","actor":"test","caused_by":"goal_1","frame_id":"frame_7","timestamp":"2026-07-24T12:00:00Z","payload":{"id":"doc#1","type":"doc","data":{}}})
    log_content = "#{header}\n#{goal}\n#{framed}\n"

    with_temp_log(log_content) do |path|
      output = Chronicle::CLI.run(["log", "inspect", "--file", path])
      output.should contain("frame_7")
    end
  end

  it "renders a causal chain from a log file" do
    header = %({"format":"chronicle.event-log","version":1})
    goal = %({"schema_version":1,"sequence":1,"id":"goal_1","type":"goal.created","actor":"user","caused_by":null,"frame_id":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"ship"}})
    obj = %({"schema_version":1,"sequence":2,"id":"evt_2","type":"object.created","actor":"test","caused_by":"goal_1","frame_id":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"id":"doc#1","type":"doc","data":{}}})
    log_content = "#{header}\n#{goal}\n#{obj}\n"

    with_temp_log(log_content) do |path|
      output = Chronicle::CLI.run(["trace", "--file", path, "--object", "doc#1"])
      output.should contain("doc#1 (doc)")
      output.should contain("goal_1")
    end
  end

  it "replays a log file and shows replay results" do
    header = %({"format":"chronicle.event-log","version":1})
    event = %({"schema_version":1,"sequence":1,"id":"evt_000001","type":"goal.created","actor":"user","caused_by":null,"timestamp":"2026-07-24T12:00:00Z","payload":{"goal":"test"}})
    log_content = "#{header}\n#{event}\n"

    with_temp_log(log_content) do |path|
      output = Chronicle::CLI.run(["replay", "--file", path])
      output.should contain("Replay complete")
      output.should_not contain("ERROR")
    end
  end

  it "diffs two logs with the structural summary and divergent objects" do
    header = %({"format":"chronicle.event-log","version":1})
    before_path = "/tmp/_clarity_cli_diff_before.log"
    after_path = "/tmp/_clarity_cli_diff_after.log"
    File.write(before_path, cli_log(header, [cli_obj_event(1_u64, "doc#1")]))
    File.write(after_path, cli_log(header, [cli_obj_event(1_u64, "doc#1"), cli_obj_event(2_u64, "doc#2")]))

    begin
      output = Chronicle::CLI.run(["diff", "-a", before_path, "-b", after_path])
      output.should contain("divergent objects:")
      output.should contain("doc#2 only in")
      output.should contain("shared_events")
      output.should_not contain("ERROR")
    ensure
      File.delete(before_path) if File.exists?(before_path)
      File.delete(after_path) if File.exists?(after_path)
    end
  end
end
