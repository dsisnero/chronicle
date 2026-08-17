require "json"
require "set"

module Chronicle
  # Native structured-output schema pre-flight and mode resolution (CONTRACT
  # v1.3 #1 #8, upstream llm/native.py + runtime.py
  # `_resolve_structured_output_mode`).
  #
  # Both shipped native modes (Anthropic `output_config`, OpenAI
  # `response_format` with `strict: true`) constrain generation with a
  # compiled grammar and accept only a subset of JSON Schema: every object
  # property must be required, only allowlisted keywords are allowed,
  # `additionalProperties` must be false, and `$ref` targets are internal and
  # non-recursive. The pre-flight is deliberately conservative — a schema
  # qualifies only if it already satisfies the subset; the framework never
  # rewrites optional fields into nullable unions or otherwise changes what
  # the schema means. The single permitted injection is
  # `additionalProperties: false` (a pure narrowing: extra keys were ignored
  # by validation, never produced meaning). A schema that does not qualify
  # resolves the behavior to prompt mode (silent-but-audited fallback, never
  # an error).
  module Native
    extend self

    # JSON Schema keywords the native grammars accept. Anything outside this
    # set (numeric/string/array constraints, pattern regexes, oneOf/not
    # composition) fails the pre-flight and the behavior stays on the
    # prompt-embedded path.
    ALLOWED_KEYWORDS = Set{
      "$defs", "$ref", "additionalProperties", "allOf", "anyOf", "const",
      "definitions", "description", "enum", "format", "items", "properties",
      "required", "title", "type",
    }

    # True when `schema` fits the native constrained-decoding subset: the root
    # is an object schema, every node uses only allowlisted keywords, every
    # object node lists all of its properties as `required`, `additionalProperties`
    # where present is already false, and `$ref` targets are internal and
    # non-recursive (upstream `native_schema_compatible`).
    def native_schema_compatible(schema : Hash(String, JSON::Any)?) : Bool
      return false if schema.nil?
      return false unless schema["type"]?.try(&.as_s?) == "object" || schema.has_key?("properties")

      defs = {} of String => JSON::Any
      {"$defs", "definitions"}.each do |key|
        block = schema[key]?.try(&.as_h?)
        block.try(&.each { |name, sub| defs[name] = sub })
      end
      node_compatible(schema, defs, [] of String)
    end

    # Deep-copy `schema` with `additionalProperties: false` on every object
    # node — the one transformation CONTRACT v1.3 #1 (#8) permits (upstream
    # `inject_additional_properties_false`). The input is never mutated.
    def inject_additional_properties_false(schema : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      copy = JSON.parse(schema.to_json).as_h
      inject_ap_false(copy)
      copy
    end

    # Resolve "native" or "prompt" for one behavior (upstream
    # `_resolve_structured_output_mode`). Native requires all four: the
    # runtime opt-in flag, a pinned model, the provider's capability claim for
    # the resolved model, and the schema passing the offline subset pre-flight.
    # Fallback is silent-but-audited — the resolved mode rides every
    # llm.requested payload, and a schema outside the subset stays on the
    # prompt-embedded path.
    def resolve_structured_output_mode(
      *,
      flag : Bool,
      model : String?,
      capability : Bool,
      schema : Hash(String, JSON::Any)?,
    ) : String
      return "prompt" unless flag
      return "prompt" if model.nil?
      return "prompt" unless capability
      return "prompt" unless native_schema_compatible(schema)
      "native"
    end

    private def node_compatible(node : Hash(String, JSON::Any)?, defs : Hash(String, JSON::Any), ref_stack : Array(String)) : Bool
      return false if node.nil?
      return false unless allowlisted?(node)

      ref_result = ref_target_result(node, defs, ref_stack)
      if !ref_result.nil?
        return ref_result
      end

      props = node["properties"]?.try(&.as_h?)
      if props
        return false unless required_exactly?(node, props)
        return false unless additional_properties_allowed?(node)

        props.each_value do |sub|
          return false unless node_compatible(sub.as_h?, defs, ref_stack)
        end
      end

      if items = node["items"]?
        return false unless node_compatible(items.as_h?, defs, ref_stack)
      end

      return false unless combinations_compatible(node, defs, ref_stack)
      return false unless defs_compatible(node, defs, ref_stack)

      true
    end

    private def allowlisted?(node : Hash(String, JSON::Any)) : Bool
      node.each_key.all? { |key| ALLOWED_KEYWORDS.includes?(key) }
    end

    # Returns nil when the node carries no `$ref`; otherwise whether the (must
    # be internal, non-recursive) ref target passes the pre-flight.
    private def ref_target_result(node : Hash(String, JSON::Any), defs : Hash(String, JSON::Any), ref_stack : Array(String)) : Bool?
      ref = node["$ref"]?.try(&.as_s?)
      return nil if ref.nil?
      return false unless ref.starts_with?("#/")

      name = ref.split('/').last
      return false if ref_stack.includes?(name)

      target = defs[name]?.try(&.as_h?)
      return false if target.nil?

      node_compatible(target, defs, ref_stack + [name])
    end

    # Every property must be listed as required (optional fields would need a
    # semantic rewrite the framework refuses to do silently).
    private def required_exactly?(node : Hash(String, JSON::Any), props : Hash(String, JSON::Any)) : Bool
      required = node["required"]?.try(&.as_a?) || [] of JSON::Any
      required_names = required.compact_map(&.as_s?)
      props.keys.sort! == required_names.sort!
    end

    private def additional_properties_allowed?(node : Hash(String, JSON::Any)) : Bool
      ap = node["additionalProperties"]?
      ap.nil? || ap.as_bool? == false
    end

    private def combinations_compatible(node : Hash(String, JSON::Any), defs : Hash(String, JSON::Any), ref_stack : Array(String)) : Bool
      {"anyOf", "allOf"}.each do |comb|
        arms = node[comb]?.try(&.as_a?)
        next if arms.nil?

        return false if arms.empty?

        arms.each do |arm|
          return false unless node_compatible(arm.as_h?, defs, ref_stack)
        end
      end
      true
    end

    private def defs_compatible(node : Hash(String, JSON::Any), defs : Hash(String, JSON::Any), ref_stack : Array(String)) : Bool
      {"$defs", "definitions"}.each do |key|
        block = node[key]?.try(&.as_h?)
        next if block.nil?

        block.each_value do |sub|
          return false unless node_compatible(sub.as_h?, defs, ref_stack)
        end
      end
      true
    end

    private def inject_ap_false(node : Hash(String, JSON::Any)) : Nil
      if node["type"]?.try(&.as_s?) == "object" || node.has_key?("properties")
        node["additionalProperties"] = JSON::Any.new(false) unless node.has_key?("additionalProperties")
      end

      node["properties"]?.try(&.as_h?).try(&.each_value do |sub|
        if sub_hash = sub.as_h?
          inject_ap_false(sub_hash)
        end
      end)

      node["items"]?.try(&.as_h?).try { |items| inject_ap_false(items) }

      {"anyOf", "allOf"}.each do |comb|
        node[comb]?.try(&.as_a?).try(&.each do |arm|
          if arm_hash = arm.as_h?
            inject_ap_false(arm_hash)
          end
        end)
      end

      {"$defs", "definitions"}.each do |key|
        node[key]?.try(&.as_h?).try(&.each_value do |sub|
          if sub_hash = sub.as_h?
            inject_ap_false(sub_hash)
          end
        end)
      end
    end
  end
end
