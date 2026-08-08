require "../spec_helper"

private class RateLimitError < Exception
  getter status_code : Int32 = 429

  def initialize(message : String)
    super(message)
  end
end

private class AuthenticationError < Exception
end

private class PermissionDeniedError < Exception
  getter status_code : Int32 = 403
end

private class NotFoundError < Exception
  getter status_code : Int32 = 404
end

private class InternalServerError < Exception
  getter status_code : Int32 = 500
end

private class APIConnectionError < Exception
end

describe Chronicle::Wire do
  describe ".sanitize_tool_name" do
    it "rewrites the pack separator (test_sanitize_rewrites_pack_separator)" do
      Chronicle::Wire.sanitize_tool_name("diligence.fetch_docs").should eq("diligence__fetch_docs")
    end

    it "is identity for wire-safe names (test_sanitize_is_identity_for_wire_safe_names)" do
      %w[fetch_docs fetch-docs Fetch2 a__b].each do |name|
        Chronicle::Wire.sanitize_tool_name(name).should eq(name)
      end
    end

    it "replaces other invalid characters (test_sanitize_replaces_other_invalid_characters)" do
      Chronicle::Wire.sanitize_tool_name("a b/c").should eq("a_b_c")
    end
  end

  describe ".build_tool_name_map" do
    it "round-trips canonical names (test_name_map_round_trips_canonical_names)" do
      tools = [
        {"name" => "diligence.lookup", "input_schema" => JSON::Any.new({} of String => JSON::Any)}.to_json,
        {"name" => "plain", "input_schema" => JSON::Any.new({} of String => JSON::Any)}.to_json,
      ]
      m = Chronicle::Wire.build_tool_name_map(tools)
      m.should eq({"diligence__lookup" => "diligence.lookup", "plain" => "plain"})
      Chronicle::Wire.restore_tool_name("diligence__lookup", m).should eq("diligence.lookup")
      Chronicle::Wire.restore_tool_name("plain", m).should eq("plain")
      Chronicle::Wire.restore_tool_name("mystery", m).should eq("mystery")
      Chronicle::Wire.restore_tool_name("x", nil).should eq("x")
    end

    it "reads OpenAI-shaped definitions (test_name_map_reads_openai_shape_definitions)" do
      tools = [{"type" => "function", "function" => {"name" => "pack.t", "parameters" => JSON::Any.new({} of String => JSON::Any)}}.to_json]
      Chronicle::Wire.build_tool_name_map(tools).should eq({"pack__t" => "pack.t"})
    end

    it "raises on collisions (test_name_map_collision_is_loud)" do
      tools = [
        {"name" => "pack.tool", "input_schema" => JSON::Any.new({} of String => JSON::Any)}.to_json,
        {"name" => "pack__tool", "input_schema" => JSON::Any.new({} of String => JSON::Any)}.to_json,
      ]
      error = expect_raises(Chronicle::ToolNameCollisionError) do
        Chronicle::Wire.build_tool_name_map(tools)
      end
      error.message.not_nil!.should contain("both sanitize")
    end
  end

  describe ".classify_provider_failure" do
    it "classifies by status code and name (test_classification_table)" do
      Chronicle::Wire.classify_provider_failure("RateLimitError", "slow down", status_code: 429).should eq("llm.rate_limited")
      Chronicle::Wire.classify_provider_failure("AuthenticationError", "bad key").should eq("llm.auth_error")
      Chronicle::Wire.classify_provider_failure("PermissionDeniedError", "no", status_code: 403).should eq("llm.auth_error")
      Chronicle::Wire.classify_provider_failure("NotFoundError", "no model", status_code: 404).should eq("llm.request_error")
      Chronicle::Wire.classify_provider_failure("InternalServerError", "oops", status_code: 500).should eq("llm.network_error")
      Chronicle::Wire.classify_provider_failure("APIConnectionError", "refused").should eq("llm.network_error")
      Chronicle::Wire.classify_provider_failure("SomethingElse", "???", status_code: 422).should eq("llm.request_error")
    end

    it "falls back to type-name heuristics when status is absent" do
      Chronicle::Wire.classify_provider_failure("BadRequestError", "bad").should eq("llm.request_error")
      Chronicle::Wire.classify_provider_failure("UnprocessableEntityError", "bad").should eq("llm.request_error")
      Chronicle::Wire.classify_provider_failure("NotFoundError", "bad").should eq("llm.request_error")
    end

    it "keeps unknown shapes transient (llm.network_error)" do
      Chronicle::Wire.classify_provider_failure("MysteryError", "???", status_code: nil).should eq("llm.network_error")
    end
  end

  describe ".classify_provider_exception" do
    it "classifies from the exception class name and status code" do
      Chronicle::Wire.classify_provider_exception(RateLimitError.new("slow down")).should eq("llm.rate_limited")
      Chronicle::Wire.classify_provider_exception(AuthenticationError.new("bad key")).should eq("llm.auth_error")
      Chronicle::Wire.classify_provider_exception(PermissionDeniedError.new("no")).should eq("llm.auth_error")
      Chronicle::Wire.classify_provider_exception(NotFoundError.new("no model")).should eq("llm.request_error")
      Chronicle::Wire.classify_provider_exception(InternalServerError.new("oops")).should eq("llm.network_error")
      Chronicle::Wire.classify_provider_exception(APIConnectionError.new("refused")).should eq("llm.network_error")
      Chronicle::Wire.classify_provider_exception(Exception.new("???")).should eq("llm.network_error")
    end
  end

  describe "retry-set taxonomy (CONTRACT v1.3 #3)" do
    it "marks auth_error and request_error terminal, network/rate_limited transient" do
      Chronicle::Wire.terminal_reason?("llm.auth_error").should be_true
      Chronicle::Wire.terminal_reason?("llm.request_error").should be_true
      Chronicle::Wire.terminal_reason?("llm.network_error").should be_false
      Chronicle::Wire.terminal_reason?("llm.rate_limited").should be_false
    end
  end
end
