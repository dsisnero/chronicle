require "../spec_helper"

# Structured-output parsing for LLM behaviors. Ported from activegraph
# llm/parsing.py `parse_structured_response` (CONTRACT v1.0.1 #5): extract JSON
# from a provider's raw output (verbatim, fenced ```json block, or first
# balanced {..} / [..] span), then validate it against a JSON::Serializable
# schema type. Two failure modes map to LLMBehaviorError reasons:
#
#   reason="llm.parse_error"       no JSON recoverable / JSON parse failed
#   reason="llm.schema_violation"  JSON recovered but the schema rejected it
#
# Ported from activegraph tests/test_llm_anthropic.py: test_complete_extracts_
# json_from_fenced_block / test_complete_raises_parse_error_when_no_json /
# test_complete_raises_schema_violation_when_json_valid_but_wrong_shape.

module StructuredOutputSpec
  struct OutStruct
    include JSON::Serializable
    property n : Int32
  end
end

describe Chronicle::StructuredOutput do
  describe ".extract_json" do
    it "passes verbatim JSON through" do
      Chronicle::StructuredOutput.extract_json(%({"n":42})).should eq(%({"n":42}))
    end

    it "extracts JSON from a fenced ```json block" do
      Chronicle::StructuredOutput.extract_json(
        "Here is the answer:\n```json\n{\"n\": 9}\n```\nDone."
      ).should eq(%({"n": 9}))
    end

    it "extracts JSON from a bare code fence without the json tag" do
      Chronicle::StructuredOutput.extract_json(
        "```\n{\"n\": 1}\n```"
      ).should eq(%({"n": 1}))
    end

    it "grabs the first balanced brace span from surrounding prose" do
      Chronicle::StructuredOutput.extract_json(
        "Sure, the result is {\"n\": 7} and that's final."
      ).should eq(%({"n": 7}))
    end

    it "returns nil for prose with no JSON" do
      Chronicle::StructuredOutput.extract_json("just prose, no json at all").should be_nil
    end
  end

  describe ".parse" do
    it "parses verbatim JSON into the schema type" do
      parsed = Chronicle::StructuredOutput.parse(%({"n":42}), StructuredOutputSpec::OutStruct)
      parsed.should be_a(StructuredOutputSpec::OutStruct)
      parsed.n.should eq(42)
    end

    it "parses JSON recovered from a fenced block" do
      parsed = Chronicle::StructuredOutput.parse(
        "Here:\n```json\n{\"n\": 9}\n```\nDone.",
        StructuredOutputSpec::OutStruct,
      )
      parsed.n.should eq(9)
    end

    it "raises llm.parse_error when no JSON is recoverable" do
      error = expect_raises(Chronicle::LLMBehaviorError) do
        Chronicle::StructuredOutput.parse("just prose, no json at all", StructuredOutputSpec::OutStruct)
      end
      error.reason.should eq("llm.parse_error")
      error.payload_extras["raw_text"]?.should_not be_nil
    end

    it "raises llm.schema_violation when JSON is valid but the wrong shape" do
      error = expect_raises(Chronicle::LLMBehaviorError) do
        Chronicle::StructuredOutput.parse(%({"oops": 1}), StructuredOutputSpec::OutStruct)
      end
      error.reason.should eq("llm.schema_violation")
      error.payload_extras["schema"]?.should_not be_nil
      error.payload_extras["raw_text"]?.should_not be_nil
      error.payload_extras["validation_errors"]?.should_not be_nil
    end
  end
end
