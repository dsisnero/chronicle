require "../spec_helper"

# Native structured-output schema pre-flight and mode resolution (CONTRACT
# v1.3 #1 #8, upstream llm/native.py + runtime.py `_resolve_structured_output_mode`).
#
# Both shipped native modes (Anthropic output_config, OpenAI response_format)
# accept only a subset of JSON Schema: every object property must be required,
# only allowlisted keywords are allowed, `additionalProperties` must be false,
# and `$ref` targets are internal and non-recursive. The pre-flight is
# conservative: a schema qualifies only if it already satisfies the subset —
# the single permitted injection is `additionalProperties: false` (a pure
# narrowing). A schema that does not qualify resolves the behavior to prompt
# mode (silent-but-audited fallback, never an error).

module NativeSpecStructs
  struct OutStruct
    include JSON::Serializable
    property n : Int32
  end

  struct LooseStruct
    include JSON::Serializable
    property a : Int32
    property b : Int32? = nil
  end
end

private def native_recursive_schema : Hash(String, JSON::Any)
  JSON.parse(%({
    "type": "object",
    "properties": {"child": {"$ref": "#/$defs/Node"}},
    "required": ["child"],
    "$defs": {
      "Node": {
        "type": "object",
        "properties": {"child": {"$ref": "#/$defs/Node"}},
        "required": ["child"]
      }
    }
  })).as_h
end

describe Chronicle::Native do
  describe ".native_schema_compatible" do
    it "accepts an all-required nested schema (test_preflight_accepts_all_required_nested_schema)" do
      Chronicle::Native.native_schema_compatible(Chronicle::Prompt.schema_to_json(NativeSpecStructs::OutStruct)).should be_true
    end

    it "rejects optional fields, constraints, and non-object roots (test_preflight_rejects_optional_fields_and_constraints)" do
      Chronicle::Native.native_schema_compatible(Chronicle::Prompt.schema_to_json(NativeSpecStructs::LooseStruct)).should be_false
      Chronicle::Native.native_schema_compatible(nil).should be_false
      Chronicle::Native.native_schema_compatible({"type" => JSON::Any.new("string")}).should be_false
      Chronicle::Native.native_schema_compatible({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new({"n" => JSON::Any.new({"type" => JSON::Any.new("integer"), "minimum" => JSON::Any.new(1_i64)})})}).should be_false
    end

    it "rejects a schema with additionalProperties not false" do
      schema = {
        "type"                 => JSON::Any.new("object"),
        "properties"           => JSON::Any.new({"n" => JSON::Any.new({"type" => JSON::Any.new("integer")})}),
        "required"             => JSON.parse(%(["n"])),
        "additionalProperties" => JSON::Any.new(true),
      }
      Chronicle::Native.native_schema_compatible(schema).should be_false
    end

    it "rejects a recursive schema (test_preflight_rejects_recursive_schema)" do
      Chronicle::Native.native_schema_compatible(native_recursive_schema).should be_false
    end
  end

  describe ".inject_additional_properties_false" do
    it "reaches nested objects without mutating the input (test_inject_additional_properties_false_reaches_nested_objects)" do
      schema = JSON.parse(%({
        "type": "object",
        "properties": {
          "claims": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {"text": {"type": "string"}, "confidence": {"type": "number"}},
              "required": ["text", "confidence"]
            }
          }
        },
        "required": ["claims"]
      })).as_h

      out = Chronicle::Native.inject_additional_properties_false(schema)
      out["additionalProperties"].as_bool.should be_false
      out["properties"].as_h["claims"].as_h["items"].as_h["additionalProperties"].as_bool.should be_false
      schema["additionalProperties"]?.should be_nil
    end
  end

  describe ".resolve_structured_output_mode" do
    compatible = Chronicle::Prompt.schema_to_json(NativeSpecStructs::OutStruct)

    it "requires the runtime opt-in flag" do
      Chronicle::Native.resolve_structured_output_mode(flag: false, model: "m", capability: true, schema: compatible).should eq("prompt")
    end

    it "requires a pinned model" do
      Chronicle::Native.resolve_structured_output_mode(flag: true, model: nil, capability: true, schema: compatible).should eq("prompt")
    end

    it "requires the provider capability claim" do
      Chronicle::Native.resolve_structured_output_mode(flag: true, model: "m", capability: false, schema: compatible).should eq("prompt")
    end

    it "falls back to prompt when the schema is outside the native subset" do
      Chronicle::Native.resolve_structured_output_mode(flag: true, model: "m", capability: true, schema: Chronicle::Prompt.schema_to_json(NativeSpecStructs::LooseStruct)).should eq("prompt")
    end

    it "resolves native only when every condition holds" do
      Chronicle::Native.resolve_structured_output_mode(flag: true, model: "m", capability: true, schema: compatible).should eq("native")
    end
  end
end
