require "json"
require "digest/sha256"
require "json-schema"

module Chronicle
  # Prompt assembler + view serializer (CONTRACT v0.6 #6, #13, #20).
  #
  # Developers don't write prompts in user code. The runtime assembles every
  # prompt from four locked sources, in this order:
  #
  #   1. system     — frame goal, frame constraints, behavior role
  #                   description, output-schema reminder
  #   2. view       — serialized scoped graph view (objects + relations +
  #                   recent events)
  #   3. event      — the triggering event, serialized as JSON
  #   4. instruction — a single sentence derived from `creates=` and
  #                   `output_schema=`
  #
  # The format of (2), the view serialization, is part of the public contract
  # per decision #13 — snapshot-tested in `spec/chronicle/prompt_spec.cr`.
  #
  # `AssembledPrompt#hash` is a stable SHA-256 over the canonical JSON of
  # {model, system, messages, output_schema_name, temperature, max_tokens,
  # top_p, deterministic} — the cache key used by the replay layer.
  #
  # `prompt_template=` (str.format-style with {system}, {view}, {event},
  # {instruction}) is the only escape hatch, and it still receives the same
  # four runtime-assembled inputs.
  module Prompt
    extend self

    # ---- canonical JSON (sorted keys, stable separators) -------------------

    # Serialize JSON::Any with hash keys sorted (byte-stable across runs,
    # mirrors Python's json.dumps(sort_keys=True)). `spaced` matches the
    # view-block default separators (`, ` / `: `); `compact` matches the
    # hash-key separators (`,` / `:`).
    def canonical_json(value : JSON::Any, *, spaced : Bool = false) : String
      case raw = value.raw
      when Nil
        "null"
      when Bool
        raw ? "true" : "false"
      when Int32, Int64
        raw.to_s
      when Float32, Float64
        raw.to_s
      when String
        raw.to_json
      when Array
        "[#{raw.map { |v| canonical_json(v, spaced: spaced) }.join(spaced ? ", " : ",")}]"
      when Hash
        sorted = raw.to_a.sort_by { |k, _| k.to_s }
        body = sorted.map { |k, v| "#{k.to_json}#{spaced ? ": " : ":"}#{canonical_json(v, spaced: spaced)}" }.join(spaced ? ", " : ",")
        "{#{body}}"
      else
        raise GraphProjectionError.new("cannot canonicalize JSON value")
      end
    end

    # ---- AssembledPrompt ---------------------------------------------------

    # A fully-assembled prompt + provider-call parameters. Returned by
    # `assemble_prompt(...)`. The runtime hashes this to look up a cached
    # response before deciding to call the provider.
    struct AssembledPrompt
      getter system : String
      getter messages : Array(LLMMessage)
      getter model : String
      getter max_tokens : Int32
      getter temperature : Float64
      getter top_p : Float64
      getter output_schema_name : String?
      getter output_schema_json : Hash(String, JSON::Any)?
      getter? deterministic : Bool
      getter structured_output_mode : String
      getter sections : Hash(String, String)

      def initialize(
        @system : String,
        @messages : Array(LLMMessage),
        @model : String,
        @max_tokens : Int32,
        @temperature : Float64,
        @top_p : Float64,
        @output_schema_name : String?,
        @output_schema_json : Hash(String, JSON::Any)?,
        @deterministic : Bool,
        @structured_output_mode : String = "prompt",
        @sections : Hash(String, String) = {} of String => String,
      )
      end

      # Canonical content used for hashing. Recorded-at timestamps,
      # latencies, and other run-specific data are NOT included. Messages
      # enter the hash via their own JSON::Serializable wire form.
      def to_hashable : Hash(String, JSON::Any)
        out = {} of String => JSON::Any
        out["model"] = JSON::Any.new(@model)
        out["system"] = JSON::Any.new(@system)
        out["messages"] = JSON::Any.new(@messages.map { |msg| JSON.parse(msg.to_json) })
        out["output_schema_name"] = JSON::Any.new(@output_schema_name.nil? ? nil : @output_schema_name)
        out["output_schema_json"] = JSON::Any.new(@output_schema_json.nil? ? nil : @output_schema_json)
        out["max_tokens"] = JSON::Any.new(@max_tokens)
        out["temperature"] = JSON::Any.new(@temperature)
        out["top_p"] = JSON::Any.new(@top_p)
        out["deterministic"] = JSON::Any.new(@deterministic)
        if @structured_output_mode == "native"
          out["structured_output_mode"] = JSON::Any.new("native")
        end
        out
      end

      def canonical_json : String
        Prompt.canonical_json(JSON::Any.new(to_hashable))
      end

      def hash : String
        ContentHash.digest(canonical_json)
      end
    end

    # ---- view serialization (CONTRACT v0.6 #13 — format is locked) --------

    def serialize_view(
      view : View,
      *,
      around : String? = nil,
      depth : Int32? = nil,
    ) : String
      header_bits = [] of String
      header_bits << "depth=#{depth}" unless depth.nil?
      header_bits << "around=#{around}" unless around.nil?
      header_suffix = header_bits.empty? ? "" : " (#{header_bits.join(", ")})"

      lines = ["## Graph context#{header_suffix}", ""]

      objects = view.objects
      lines << "### Objects"
      if objects.empty?
        lines << "- (none)"
      else
        objects.each do |obj|
          lines << "- #{obj.id} (#{obj.type}): #{canonical_object_data(obj.data)}"
        end
      end
      lines << ""

      relations = view.relations
      lines << "### Relations"
      if relations.empty?
        lines << "- (none)"
      else
        relations.each do |rel|
          lines << "- #{rel.from_id} --#{rel.type}--> #{rel.to_id}"
        end
      end
      lines << ""

      events = view.events
      lines << "### Recent events"
      if events.empty?
        lines << "- (none)"
      else
        events.each do |e|
          lines << "- #{e.id} #{e.type}#{event_summary(e)}"
        end
      end

      lines.join("\n")
    end

    # One-line tail for an event in the view block. Reads Chronicle's flat
    # payload shapes (`object.created` carries `id`/`type`/`data`; upstream
    # nests them under `object`/`relation`).
    private def event_summary(e : Event) : String
      payload = begin
        JSON.parse(e.payload).as_h
      rescue JSON::ParseException
        return ""
      end

      case e.type
      when "object.created"
        id = payload["id"]?.try(&.as_s) || "?"
        " #{id}"
      when "relation.created"
        source = payload["from_id"]?.try(&.as_s) || "?"
        rel_type = payload["type"]?.try(&.as_s) || "?"
        target = payload["to_id"]?.try(&.as_s) || "?"
        " #{source} --#{rel_type}--> #{target}"
      when "patch.applied"
        target = payload["target"]?.try(&.as_s) || "?"
        " #{target}"
      when "goal.created"
        goal = payload["goal"]?.try(&.as_s) || ""
        %( "#{goal}")
      else
        ""
      end
    end

    # Stable sorted JSON for embedding object data inside the view block.
    private def canonical_object_data(data : String) : String
      value = JSON.parse(data)
      canonical_json(value, spaced: true)
    rescue JSON::ParseException
      data
    end

    # ---- system prompt -----------------------------------------------------

    # The system prompt is assembled — never hand-written by the user.
    # Source order: frame.goal → frame.constraints → behavior.description →
    # output schema reminder. Absent sections are omitted; the section
    # headers themselves are stable so snapshot tests are tight.
    def build_system_prompt(
      *,
      behavior_name : String,
      description : String,
      frame : Frame?,
      output_schema_name : String?,
      output_schema_json : Hash(String, JSON::Any)?,
      structured_output_mode : String = "prompt",
    ) : String
      blocks = [] of String

      blocks << %(You are an active-graph behavior named "#{behavior_name}".)

      if f = frame
        unless f.goal.empty?
          blocks << "Mission: #{f.goal}"
        end
        unless f.constraints.empty?
          bullets = f.constraints.map { |constraint| "- #{constraint}" }.join("\n")
          blocks << "Constraints:\n#{bullets}"
        end
      end

      unless description.empty?
        blocks << "Role: #{description}"
      end

      if output_schema_name && structured_output_mode == "native"
        blocks << "Respond with JSON that matches the `#{output_schema_name}` schema."
      elsif output_schema_name && output_schema_json
        schema_block = canonical_json(JSON::Any.new(output_schema_json), spaced: false)
        example = example_instance_from_schema(output_schema_json)
        example_block = canonical_json(example, spaced: false)
        blocks << (
          "Respond with JSON that matches the `#{output_schema_name}` " \
          "schema. Return an INSTANCE that conforms to this schema, " \
          "NOT the schema itself.\n" \
          "\n" \
          "Schema:\n#{schema_block}\n" \
          "\n" \
          "Example instance (the shape your response must take, with " \
          "placeholder values — replace them with real values):\n" \
          "#{example_block}"
        )
      end

      blocks.join("\n\n")
    end

    # Build a minimal example instance from a JSON Schema dict. Deterministic
    # placeholder values per type; bounded recursion (depth ceiling).
    def example_instance_from_schema(schema : Hash(String, JSON::Any)) : JSON::Any
      defs = (schema["$defs"]? || schema["definitions"]?).try(&.as_h?) || {} of String => JSON::Any
      example_instance(JSON::Any.new(schema), defs: defs, depth: 0)
    end

    private PLACEHOLDER_BY_TYPE = {
      "string"  => JSON::Any.new("<string>"),
      "integer" => JSON::Any.new(0),
      "number"  => JSON::Any.new(0.0),
      "boolean" => JSON::Any.new(true),
      "null"    => JSON::Any.new(nil),
    }

    private def example_instance(node : JSON::Any, *, defs : Hash(String, JSON::Any), depth : Int32) : JSON::Any
      return JSON::Any.new(nil) unless node.raw.is_a?(Hash(String, JSON::Any)) && depth <= 6
      hash = node.as_h

      if resolved = resolve_ref(node, hash, defs, depth)
        return resolved
      end

      if enum_values = hash["enum"]?.try(&.as_a)
        return enum_values.first unless enum_values.empty?
      end

      if const = hash["const"]?
        return const
      end

      if variant = pick_variant(hash, defs, depth)
        return variant
      end

      if st = hash["type"]?
        if st.raw.is_a?(Array(JSON::Any))
          non_null = st.as_a.reject { |entry| entry.raw.is_a?(String) && entry.as_s == "null" }
          schema_type = non_null.first? || JSON::Any.new("null")
        else
          schema_type = st
        end
      else
        schema_type = nil
      end

      example_for_type(schema_type, hash, defs, depth)
    end

    private def example_for_type(
      schema_type : JSON::Any?,
      hash : Hash(String, JSON::Any),
      defs : Hash(String, JSON::Any),
      depth : Int32,
    ) : JSON::Any
      case schema_type.try(&.as_s)
      when "object"
        object_example(hash, defs, depth)
      when "array"
        items = hash["items"]? || JSON::Any.new({} of String => JSON::Any)
        JSON::Any.new([example_instance(items, defs: defs, depth: depth + 1)])
      when "string", "integer", "number", "boolean", "null"
        PLACEHOLDER_BY_TYPE.fetch(schema_type.try(&.as_s).to_s, JSON::Any.new(nil))
      else
        if hash.has_key?("properties")
          merged = hash.dup
          merged["type"] = JSON::Any.new("object")
          example_instance(JSON::Any.new(merged), defs: defs, depth: depth)
        else
          JSON::Any.new(nil)
        end
      end
    end

    private def resolve_ref(
      node : JSON::Any,
      hash : Hash(String, JSON::Any),
      defs : Hash(String, JSON::Any),
      depth : Int32,
    ) : JSON::Any?
      ref = hash["$ref"]?.try(&.as_s)
      return nil unless ref && ref.starts_with?("#/$defs/")

      key = ref[8..]
      target = defs[key]?
      target ? example_instance(target, defs: defs, depth: depth + 1) : nil
    end

    private def pick_variant(
      hash : Hash(String, JSON::Any),
      defs : Hash(String, JSON::Any),
      depth : Int32,
    ) : JSON::Any?
      {"anyOf", "oneOf"}.each do |variant_key|
        variants = hash[variant_key]?.try(&.as_a)
        next if variants.nil? || variants.empty?

        non_null = variants.select { |v| v.raw.is_a?(Hash(String, JSON::Any)) && v.as_h["type"]?.try(&.as_s) != "null" }
        choice = non_null.first? || variants.first
        return example_instance(choice, defs: defs, depth: depth + 1)
      end
      nil
    end

    private def object_example(
      hash : Hash(String, JSON::Any),
      defs : Hash(String, JSON::Any),
      depth : Int32,
    ) : JSON::Any
      properties = hash["properties"]?.try(&.as_h) || {} of String => JSON::Any
      return JSON::Any.new({} of String => JSON::Any) if properties.empty?

      built = properties.to_h do |name, spec|
        {name, example_instance(spec, defs: defs, depth: depth + 1)}
      end
      JSON::Any.new(built)
    end

    # ---- user message ------------------------------------------------------

    def build_user_message(
      *,
      view_block : String,
      event : Event,
      instruction : String,
    ) : String
      event_block = serialize_event(event)
      "#{view_block}\n\n" \
      "## Triggering event\n" \
      "#{event_block}\n\n" \
      "## Task\n" \
      "#{instruction}"
    end

    private def serialize_event(event : Event) : String
      clean_payload = strip_volatile(JSON.parse(event.payload))
      payload_json = canonical_json(clean_payload, spaced: false)
      "- id: #{event.id}\n" \
      "- type: #{event.type}\n" \
      "- actor: #{event.actor.empty? ? "?" : event.actor}\n" \
      "- payload:\n```\n#{payload_json}\n```"
    end

    VOLATILE_KEYS = Set{"provenance", "timestamp", "run_id"}

    # Recursively drop keys whose values vary across runs/forks. Provenance
    # carries run_id and timestamp; both leak into embedded object payloads
    # and would otherwise destabilize the prompt hash.
    def strip_volatile(value : JSON::Any) : JSON::Any
      case raw = value.raw
      when Hash(String, JSON::Any)
        cleaned = raw.to_h do |k, v|
          next {k, strip_volatile(v)} unless VOLATILE_KEYS.includes?(k)
          {k, JSON::Any.new(nil)}
        end.reject { |k, _v| VOLATILE_KEYS.includes?(k) }
        JSON::Any.new(cleaned)
      when Array(JSON::Any)
        JSON::Any.new(raw.map { |v| strip_volatile(v) })
      else
        value
      end
    end

    # ---- task instruction --------------------------------------------------

    def build_instruction(
      *,
      creates : Array(String),
      output_schema_name : String?,
    ) : String
      if output_schema_name && !creates.empty?
        creates_str = creates.sort.uniq!.join(", ")
        "Return a JSON instance of the `#{output_schema_name}` schema " \
        "(NOT the schema definition itself — see the example above). " \
        "Your output will be used to create objects of type: #{creates_str}."
      elsif output_schema_name
        "Return a JSON instance of the `#{output_schema_name}` schema " \
        "(NOT the schema definition itself — see the example above)."
      elsif !creates.empty?
        creates_str = creates.sort.uniq!.join(", ")
        "Describe what objects of type #{creates_str} should be created " \
        "in response to this event."
      else
        "Describe what should happen in response to this event."
      end
    end

    # ---- schema rendering --------------------------------------------------

    # Serialize a JSON::Serializable type to its JSON Schema dict (nil for
    # no schema). Ported from activegraph.llm.prompt.schema_to_json; Crystal
    # derives the schema from the struct's typed fields + enums at compile
    # time via the json-schema shard, replacing Pydantic's model_json_schema.
    # When `output_schema` is omitted the default `Nil.class` resolves the
    # generic to `Object`, which we treat as "no schema".
    def schema_to_json(schema : T.class) : Hash(String, JSON::Any)? forall T
      {% if T.name == "Nil" || T.name == "Object" %}
        nil
      {% else %}
        JSON.parse({{ T }}.json_schema.to_json).as_h
      {% end %}
    end

    # Name-only shell when only a schema name is known (no typed struct).
    def schema_to_json(schema_name : String) : Hash(String, JSON::Any)
      {"type" => JSON::Any.new("object"), "title" => JSON::Any.new(schema_name)}
    end

    # The output-schema name derived from a type (nil when absent).
    def schema_name(schema : T.class) : String? forall T
      {% if T.name == "Nil" || T.name == "Object" %}
        nil
      {% else %}
        {{ T }}.name.split("::").last
      {% end %}
    end

    # ---- top-level assembly -----------------------------------------------

    def assemble_prompt(
      *,
      behavior_name : String,
      description : String,
      model : String,
      output_schema : T.class = Nil.class,
      creates : Array(String),
      view : View,
      event : Event,
      frame : Frame?,
      around : String?,
      depth : Int32?,
      max_tokens : Int32,
      temperature : Float64,
      top_p : Float64,
      deterministic : Bool,
      prompt_template : String? = nil,
      structured_output_mode : String = "prompt",
    ) : AssembledPrompt forall T
      schema_json = schema_to_json(output_schema)
      schema_name = schema_name(output_schema)

      system = build_system_prompt(
        behavior_name: behavior_name,
        description: description,
        frame: frame,
        output_schema_name: schema_name,
        output_schema_json: schema_json,
        structured_output_mode: structured_output_mode,
      )

      view_block = serialize_view(view, around: around, depth: depth)
      instruction = build_instruction(creates: creates, output_schema_name: schema_name)

      user_text = if template = prompt_template
                    apply_prompt_template(template, system: system, view: view_block, event: serialize_event(event), instruction: instruction)
                  else
                    build_user_message(view_block: view_block, event: event, instruction: instruction)
                  end

      eff_temperature = deterministic ? 0.0 : temperature
      eff_top_p = deterministic ? 1.0 : top_p

      AssembledPrompt.new(
        system: system,
        messages: [LLMMessage.new(role: Role::User, content: user_text)],
        model: model,
        max_tokens: max_tokens,
        temperature: eff_temperature,
        top_p: eff_top_p,
        output_schema_name: schema_name,
        output_schema_json: schema_json,
        deterministic: deterministic,
        structured_output_mode: structured_output_mode,
        sections: {
          "system"      => system,
          "view"        => view_block,
          "event"       => serialize_event(event),
          "instruction" => instruction,
          "user"        => user_text,
        },
      )
    end

    # str.format-style placeholder substitution. Unknown placeholders raise
    # PromptTemplateError (upstream ValueError).
    private def apply_prompt_template(
      template : String,
      *,
      system : String,
      view : String,
      event : String,
      instruction : String,
    ) : String
      allowed = {"system" => system, "view" => view, "event" => event, "instruction" => instruction}
      template.gsub(/\{(\w+)\}/) do |_match|
        key = $1
        if value = allowed[key]?
          value
        else
          raise PromptTemplateError.new(
            "prompt_template references unknown placeholder {#{key}}. " \
            "Allowed: {system}, {view}, {event}, {instruction}"
          )
        end
      end
    end
  end
end
