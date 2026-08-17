module Chronicle
  module Packs
    # The Crystal analogue of Python's pack-aware decorators. In activegraph a
    # pack module uses `@behavior` / `@llm_behavior` / `@relation_behavior` /
    # `@tool` imported from `activegraph.packs`; in Chronicle a pack module
    # annotates its methods/structs with these annotations and the `DSL.pack`
    # macro collects them at compile time. Neither approach registers anything
    # globally — the Pack constructor is the only thing that sees these
    # objects (CONTRACT v0.9 #3).
    #
    # Nested in `Annotations` so the annotation names don't collide with the
    # `ObjectType` / `RelationType` value objects in the same namespace.
    module Annotations
      annotation Behavior
      end

      annotation LLMBehavior
      end

      annotation RelationBehavior
      end

      annotation Tool
      end

      annotation ObjectType
      end

      annotation RelationType
      end
    end

    # Evaluate a `where:` predicate against an event payload. Mirrors
    # activegraph.core.graph.evaluate_where: dotted-path keys, literal
    # equality or `{"op" => value}` comparisons, reusing the WHERE_OPS table.
    def self.where_matches?(where : Hash(String, JSON::Any), payload : String) : Bool
      root = JSON.parse(payload)
      where.each do |key, expected|
        actual = resolve_where_path(root, key.split('.'))
        if expected.raw.is_a?(Hash(String, JSON::Any))
          expected.raw.as(Hash(String, JSON::Any)).each do |op, value|
            fn = GraphProjection::WHERE_OPS[op]?
            return false if fn.nil?
            return false unless fn.call(actual, value)
          end
        else
          return false unless JsonCompare.json_equal?(actual, expected)
        end
      end
      true
    end

    def self.resolve_where_path(root : JSON::Any, path : Array(String)) : JSON::Any
      cur = root
      path.each do |segment|
        if cur.raw.is_a?(Hash(String, JSON::Any))
          hash = cur.raw.as(Hash(String, JSON::Any))
          cur = hash[segment]? || JSON::Any.new(nil)
        else
          return JSON::Any.new(nil)
        end
      end
      cur
    end

    # DSL mixed into a pack module via `include Chronicle::Packs::DSL`. The
    # `pack` macro collects `@[Behavior]` / `@[LLMBehavior]` /
    # `@[RelationBehavior]` / `@[Tool]` / `@[ObjectType]` / `@[RelationType]`
    # declarations from the module, builds the frozen `Pack` manifest, and
    # registers it (unless `register: false`).
    #
    # Behaviors/tools are declared as instance defs (`def ping(...)`); the
    # include auto-`extend self`s the module so the generated handlers can
    # call them as `Module.ping(...)`.
    module DSL
      macro included
        # Bring the annotation names into the pack module's scope so pack
        # authors write `@[Behavior(...)]`, `@[Tool(...)]`, `@[ObjectType(...)]`
        # instead of the fully-qualified path. Behaviors/tools are declared as
        # instance defs; `extend self` makes them callable as `Module.foo`.
        include ::Chronicle::Packs::Annotations
        extend self
      end

      macro pack(
        name,
        version,
        description = "",
        settings_schema = nil,
        object_types = nil,
        relation_types = nil,
        behaviors = nil,
        tools = nil,
        policies = nil,
        prompts = nil,
        capabilities = nil,
        register = true,
      )
        {%
          type = @type
          has_settings = !settings_schema.is_a?(NilLiteral)
        %}
        {% if has_settings && settings_schema.stringify != "Chronicle::Packs::EmptySettings" && settings_schema.stringify != "EmptySettings" %}
          {% unless settings_schema.is_a?(Path) || settings_schema.is_a?(TypeNode) || settings_schema.is_a?(Generic) %}
            {% raise "pack: settings_schema must be a type (a JSON::Serializable struct including Chronicle::Packs::SettingsSchema)" %}
          {% end %}
        {% end %}

        PACK = ::Chronicle::Packs::Pack.new(
          name: {{ name }},
          version: {{ version }},
          description: {{ description }},
          settings_schema: {% if has_settings %}{{ settings_schema }}.pack_settings_name{% else %}"EmptySettings"{% end %},
          settings_builder: {% if has_settings %}
            ->(input : JSON::Any?) : Hash(String, JSON::Any) { {{ settings_schema }}.build_pack_settings(input) },
          {% else %}
            ::Chronicle::Packs::DEFAULT_SETTINGS_BUILDER,
          {% end %}
          object_types: [
            {% for cnode in type.constants %}
              {% if ann = type.constant(cnode).annotation(::Chronicle::Packs::Annotations::ObjectType) %}
                ::Chronicle::Packs::ObjectType.new(
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ cnode }}{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                  validator: ->(data : String) : String { {{ cnode }}.from_json(data).to_json },
                ),
              {% end %}
            {% end %}
            {% if object_types %}{{ object_types }}{% end %}
          ] of ::Chronicle::Packs::ObjectType,
          relation_types: [
            {% for cnode in type.constants %}
              {% if ann = type.constant(cnode).annotation(::Chronicle::Packs::Annotations::RelationType) %}
                ::Chronicle::Packs::RelationType.new(
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ cnode }}{% end %},
                  source_types: {% if ann[:source_types] %}{{ ann[:source_types] }}{% else %}[] of String{% end %},
                  target_types: {% if ann[:target_types] %}{{ ann[:target_types] }}{% else %}[] of String{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                ),
              {% end %}
            {% end %}
            {% if relation_types %}{{ relation_types }}{% end %}
          ] of ::Chronicle::Packs::RelationType,
          behaviors: [
            {% for method in type.methods %}
              {% if ann = method.annotation(::Chronicle::Packs::Annotations::Behavior) %}
                {% if method.args.any? { |arg| arg.name == :settings } && !has_settings %}
                  {% raise "pack: behavior #{(ann[:name] || method.name).stringify} declares a `settings` parameter but the pack declares no settings_schema" %}
                {% end %}
                ::Chronicle::Packs::PackBehavior.new(
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ method.name }}{% end %},
                  event_types: {% if ann[:on] %}{{ ann[:on] }}{% else %}[] of String{% end %},
                  {% if ann[:where].is_a?(HashLiteral) %}
                    where: {
                      {% for key, value in ann[:where] %}
                        {{ key }} => {% if value.is_a?(StringLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(NumberLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(BoolLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(NilLiteral) %}::JSON::Any.new(nil){% else %}::JSON::Any.new({{ value }}){% end %},
                      {% end %}
                    } of String => ::JSON::Any,
                  {% else %}
                    where: nil,
                  {% end %}
                  priority: {% if ann[:priority] %}{{ ann[:priority] }}{% else %}0{% end %},
                  creates: {% if ann[:creates] %}{{ ann[:creates] }}{% else %}[] of String{% end %},
                  pattern: {% if ann[:pattern] %}{{ ann[:pattern] }}{% else %}nil{% end %},
                  activate_after: {% if ann[:activate_after] %}::Chronicle::Packs.parse_activate_after({{ ann[:activate_after] }}){% else %}nil{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                  handler: ->(event : ::Chronicle::Event, graph : ::Chronicle::GraphProjection, ctx : ::Chronicle::Packs::BehaviorContext) : Nil {
                    {% if method.args.any? { |arg| arg.name == :settings } %}
                      {{ type }}.{{ method.name }}(event, graph, ctx, {{ settings_schema }}.from_json(ctx.settings.to_json))
                    {% else %}
                      {{ type }}.{{ method.name }}(event, graph, ctx)
                    {% end %}
                  },
                ),
              {% elsif ann = method.annotation(::Chronicle::Packs::Annotations::RelationBehavior) %}
                ::Chronicle::Packs::PackBehavior.new(
                  kind: ::Chronicle::Packs::PackBehaviorKind::Relation,
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ method.name }}{% end %},
                  relation_type: {% if ann[:relation_type] %}{{ ann[:relation_type] }}{% else %}{% raise "pack: @[RelationBehavior] requires relation_type" %}{% end %},
                  event_types: {% if ann[:on] %}{{ ann[:on] }}{% else %}[] of String{% end %},
                  {% if ann[:where].is_a?(HashLiteral) %}
                    where: {
                      {% for key, value in ann[:where] %}
                        {{ key }} => {% if value.is_a?(StringLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(NumberLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(BoolLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(NilLiteral) %}::JSON::Any.new(nil){% else %}::JSON::Any.new({{ value }}){% end %},
                      {% end %}
                    } of String => ::JSON::Any,
                  {% else %}
                    where: nil,
                  {% end %}
                  priority: {% if ann[:priority] %}{{ ann[:priority] }}{% else %}0{% end %},
                  creates: {% if ann[:creates] %}{{ ann[:creates] }}{% else %}[] of String{% end %},
                  pattern: {% if ann[:pattern] %}{{ ann[:pattern] }}{% else %}nil{% end %},
                  activate_after: {% if ann[:activate_after] %}::Chronicle::Packs.parse_activate_after({{ ann[:activate_after] }}){% else %}nil{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                  relation_handler: ->(relation : ::Chronicle::GraphRelation, event : ::Chronicle::Event, graph : ::Chronicle::GraphProjection, ctx : ::Chronicle::Packs::BehaviorContext) : Nil {
                    {% if method.args.any? { |arg| arg.name == :settings } %}
                      {{ type }}.{{ method.name }}(relation, event, graph, ctx, {{ settings_schema }}.from_json(ctx.settings.to_json))
                    {% else %}
                      {{ type }}.{{ method.name }}(relation, event, graph, ctx)
                    {% end %}
                  },
                ),
              {% elsif ann = method.annotation(::Chronicle::Packs::Annotations::LLMBehavior) %}
                ::Chronicle::Packs::PackBehavior.new(
                  kind: ::Chronicle::Packs::PackBehaviorKind::LLM,
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ method.name }}{% end %},
                  event_types: {% if ann[:on] %}{{ ann[:on] }}{% else %}[] of String{% end %},
                  {% if ann[:where].is_a?(HashLiteral) %}
                    where: {
                      {% for key, value in ann[:where] %}
                        {{ key }} => {% if value.is_a?(StringLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(NumberLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(BoolLiteral) %}::JSON::Any.new({{ value }}){% elsif value.is_a?(NilLiteral) %}::JSON::Any.new(nil){% else %}::JSON::Any.new({{ value }}){% end %},
                      {% end %}
                    } of String => ::JSON::Any,
                  {% else %}
                    where: nil,
                  {% end %}
                  priority: {% if ann[:priority] %}{{ ann[:priority] }}{% else %}0{% end %},
                  creates: {% if ann[:creates] %}{{ ann[:creates] }}{% else %}[] of String{% end %},
                  pattern: {% if ann[:pattern] %}{{ ann[:pattern] }}{% else %}nil{% end %},
                  activate_after: {% if ann[:activate_after] %}::Chronicle::Packs.parse_activate_after({{ ann[:activate_after] }}){% else %}nil{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                  model: {% if ann[:model] %}{{ ann[:model] }}{% else %}"claude-sonnet-4-5"{% end %},
                  prompt_template: {% if ann[:prompt_template] %}{{ ann[:prompt_template] }}{% else %}nil{% end %},
                  max_tokens: {% if ann[:max_tokens] %}{{ ann[:max_tokens] }}{% else %}4096{% end %},
                  temperature: {% if ann[:temperature] %}{{ ann[:temperature] }}{% else %}0.7{% end %},
                  max_tool_turns: {% if ann[:max_tool_turns] %}{{ ann[:max_tool_turns] }}{% else %}6{% end %},
                  tools: {% if ann[:tools] %}{{ ann[:tools] }}{% else %}[] of String{% end %},
                  output_schema_name: {% if ann[:output_schema] %}::Chronicle::Prompt.schema_name({{ ann[:output_schema] }}){% else %}nil{% end %},
                  output_schema_json: {% if ann[:output_schema] %}::Chronicle::Prompt.schema_to_json({{ ann[:output_schema] }}){% else %}nil{% end %},
                  llm_handler: ->(event : ::Chronicle::Event, graph : ::Chronicle::GraphProjection, ctx : ::Chronicle::Packs::BehaviorContext, output : String) : Nil {
                    {% if ann[:output_schema] %}
                      # Structured-output schema typing (upstream llm/parsing.py
                      # parse_structured_response): the raw provider text is
                      # extracted + validated into the schema type, and the
                      # handler receives the typed value. Parse/schema failures
                      # raise LLMBehaviorError (llm.parse_error /
                      # llm.schema_violation) folded to behavior.failed.
                      parsed = ::Chronicle::StructuredOutput.parse(output, {{ ann[:output_schema] }})
                      {% if method.args.any? { |arg| arg.name == :settings } %}
                        {{ type }}.{{ method.name }}(event, graph, ctx, parsed, {{ settings_schema }}.from_json(ctx.settings.to_json))
                      {% else %}
                        {{ type }}.{{ method.name }}(event, graph, ctx, parsed)
                      {% end %}
                    {% else %}
                      {% if method.args.any? { |arg| arg.name == :settings } %}
                        {{ type }}.{{ method.name }}(event, graph, ctx, output, {{ settings_schema }}.from_json(ctx.settings.to_json))
                      {% else %}
                        {{ type }}.{{ method.name }}(event, graph, ctx, output)
                      {% end %}
                    {% end %}
                  },
                ),
              {% end %}
            {% end %}
            {% if behaviors %}{{ behaviors }}{% end %}
          ] of ::Chronicle::Packs::PackBehavior,
          tools: [
            {% for method in type.methods %}
              {% if ann = method.annotation(::Chronicle::Packs::Annotations::Tool) %}
                {% for arg in method.args %}
                  {% if arg.name != :args && arg.name != :ctx %}
                    {% raise "pack: @[Tool] methods may only declare `args` and an optional `ctx` parameter" %}
                  {% end %}
                {% end %}
                {% if method.args.any? { |arg| arg.name == :ctx } %}
                ::Chronicle::Tool.new(
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ method.name }}{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                  deterministic: {% if ann[:deterministic] %}{{ ann[:deterministic] }}{% else %}false{% end %},
                  pack_local: true,
                  export_globally: {% if ann[:export_globally] %}{{ ann[:export_globally] }}{% else %}false{% end %},
                  {% if ann[:input_schema] %}
                    input_validator: ->(args : String) : Nil {
                      {{ ann[:input_schema] }}.from_json(args)
                      nil
                    },
                  {% end %}
                  ctx_fn: ->(args : String, ctx : ::Chronicle::ToolContext) : String {
                    {{ type }}.{{ method.name }}(args, ctx)
                  },
                ) { |args| {{ type }}.{{ method.name }}(args, ::Chronicle::ToolContext.new) },
                {% else %}
                ::Chronicle::Tool.new(
                  name: {% if ann[:name] %}{{ ann[:name] }}{% else %}{{ method.name }}{% end %},
                  description: {% if ann[:description] %}{{ ann[:description] }}{% else %}""{% end %},
                  deterministic: {% if ann[:deterministic] %}{{ ann[:deterministic] }}{% else %}false{% end %},
                  pack_local: true,
                  export_globally: {% if ann[:export_globally] %}{{ ann[:export_globally] }}{% else %}false{% end %},
                  {% if ann[:input_schema] %}
                    input_validator: ->(args : String) : Nil {
                      {{ ann[:input_schema] }}.from_json(args)
                      nil
                    },
                  {% end %}
                ) { |args| {{ type }}.{{ method.name }}(args) },
                {% end %}
              {% end %}
            {% end %}
            {% if tools %}{{ tools }}{% end %}
          ] of ::Chronicle::Tool,
          policies: {% if policies %}{{ policies }}{% else %}[] of ::Chronicle::Packs::PackPolicy{% end %},
          prompts: {% if prompts %}{{ prompts }}{% else %}[] of ::Chronicle::Packs::PackPrompt{% end %},
          capabilities: {% if capabilities %}{{ capabilities }}{% else %}[] of ::Chronicle::Packs::CapabilityDecl{% end %},
        )

        # The manifest, queryable like upstream's module-level `pack`.
        def self.pack : ::Chronicle::Packs::Pack
          PACK
        end

        {% if register %}
          ::Chronicle::Packs::Registry.register(PACK)
        {% end %}
      end
    end
  end
end
