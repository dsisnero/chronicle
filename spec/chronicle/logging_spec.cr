require "../spec_helper"

private def log_line(
  level : String = "INFO",
  logger : String = "activegraph.test",
  message : String = "hello",
  extras : Hash(String, JSON::Any) = {} of String => JSON::Any,
  timestamp : String = "2026-05-15T10:32:01.000Z",
) : Hash(String, JSON::Any)
  line = Chronicle::Logging.format_line(
    timestamp: timestamp,
    level: level,
    logger: logger,
    message: message,
    extras: extras,
  )
  JSON.parse(line).as_h
end

describe Chronicle::Logging do
  describe "LOG_FIELDS" do
    it "pins the documented log schema (test_log_fields_schema_snapshot)" do
      Chronicle::Logging::LOG_FIELDS.should eq(
        [
          "timestamp", "level", "logger", "message",
          "run_id", "event_id", "behavior", "tool", "model",
          "cache_hit", "cost_usd", "latency_seconds", "reason",
          "error_type", "error_message", "doc_url",
        ]
      )
    end
  end

  describe ".format_line" do
    it "emits valid JSON with required fields always present (test_required_fields_always_present)" do
      obj = log_line(message: "hello")
      obj["level"].as_s.should eq("INFO")
      obj["logger"].as_s.should eq("activegraph.test")
      obj["message"].as_s.should eq("hello")
      obj.has_key?("timestamp").should be_true
    end

    it "omits optional fields when absent (test_optional_fields_omitted_when_absent)" do
      obj = log_line(message: "hello")
      %w[run_id event_id behavior tool model].each do |key|
        obj.has_key?(key).should be_false, "#{key} should be omitted, got #{obj}"
      end
    end

    it "passes documented fields through (test_documented_fields_pass_through)" do
      obj = log_line(
        message: "behavior fired",
        extras: {
          "run_id"          => JSON::Any.new("run_x"),
          "event_id"        => JSON::Any.new("evt_1"),
          "behavior"        => JSON::Any.new("planner"),
          "latency_seconds" => JSON::Any.new(0.012),
          "cost_usd"        => JSON::Any.new("0.0042"),
          "cache_hit"       => JSON::Any.new(false),
        },
      )
      obj["run_id"].as_s.should eq("run_x")
      obj["event_id"].as_s.should eq("evt_1")
      obj["behavior"].as_s.should eq("planner")
      obj["latency_seconds"].as_f.should eq(0.012)
      obj["cost_usd"].as_s.should eq("0.0042")
      obj["cache_hit"].as_bool.should be_false
    end

    it "drops undocumented fields (test_undocumented_fields_dropped)" do
      obj = log_line(
        message: "x",
        extras: {
          "run_id"         => JSON::Any.new("r"),
          "custom_unknown" => JSON::Any.new("value"),
        },
      )
      obj["run_id"].as_s.should eq("r")
      obj.has_key?("custom_unknown").should be_false
    end

    it "serializes to one compact JSON object (test_every_line_is_valid_json)" do
      line = Chronicle::Logging.format_line(
        timestamp: "2026-05-15T10:32:01.000Z",
        level: "WARNING",
        logger: "activegraph.test",
        message: "uh oh",
        extras: {"run_id" => JSON::Any.new("run_x"), "behavior" => JSON::Any.new("b1")},
      )
      JSON.parse(line).should be_a(JSON::Any)
      line.should_not contain("  ")
    end
  end

  describe ".runtime_log_extra" do
    it "builds an extras dict dropping nil values (test_runtime_log_extra_drops_none)" do
      extras = Chronicle::Logging.runtime_log_extra(
        run_id: "run_x",
        event_id: "evt_1",
        behavior: nil,
      )
      extras.keys.sort.should eq(["event_id", "run_id"])
    end

    it "renames reserved LogRecord attribute collisions (test_reserved_attr_renamed)" do
      extras = Chronicle::Logging.runtime_log_extra(message: "collides", process: 42)
      extras.has_key?("message").should be_false
      extras.has_key?("ag_message").should be_true
      extras.has_key?("ag_process").should be_true
    end
  end

  describe ".set_payload_redactor / .redact_payload" do
    it "applies the installed redactor to payloads" do
      Chronicle::Logging.set_payload_redactor(->(payload : Hash(String, JSON::Any)) : Hash(String, JSON::Any) {
        out = payload.dup
        out["api_key"] = JSON::Any.new("REDACTED")
        out
      })
      out = Chronicle::Logging.redact_payload({"secret" => JSON::Any.new("x")})
      out["secret"].as_s.should eq("x")
      out["api_key"].as_s.should eq("REDACTED")
      Chronicle::Logging.set_payload_redactor(nil)
    end

    it "is identity when no redactor is installed" do
      Chronicle::Logging.set_payload_redactor(nil)
      out = Chronicle::Logging.redact_payload({"a" => JSON::Any.new(1)})
      out.should eq({"a" => JSON::Any.new(1)})
    end
  end
end
