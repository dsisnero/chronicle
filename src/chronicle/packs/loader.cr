module Chronicle
  module Packs
    # A deferred object creation gated behind a policy approval. `id` is
    # unique within the runtime and reused as the eventual object id once
    # approved. Mirrors activegraph.packs.PendingApproval.
    struct PackPendingApproval
      getter id : String
      getter kind : String
      getter object_type : String
      getter data : String
      getter reason : String
      getter pack : String

      def initialize(
        @id : String,
        @kind : String,
        @object_type : String,
        @data : String,
        @reason : String,
        @pack : String,
      )
      end
    end

    # Per-runtime pack bookkeeping. Lives on Runtime under `pack_state`.
    # Mirrors activegraph.packs.loader.PackRuntimeState.
    class PackRuntimeState
      getter loaded_packs : Hash(String, Pack)
      getter pack_settings : Hash(String, Hash(String, JSON::Any))
      getter behavior_owners : Hash(String, String)
      getter tool_owners : Hash(String, String)
      getter policy_owners : Hash(String, String)
      getter object_type_owners : Hash(String, String)
      getter relation_type_owners : Hash(String, String)
      getter behavior_short_to_canonical : Hash(String, String)
      getter tool_short_to_canonical : Hash(String, String)
      getter object_type_schemas : Hash(String, (String -> String))
      getter relation_type_specs : Hash(String, RelationType)
      getter gated_object_types : Hash(String, Array(String))
      getter pack_pending_approvals : Array(PackPendingApproval)
      getter disabled_packs : Set(String)
      property next_approval_n : Int32

      def initialize
        @loaded_packs = {} of String => Pack
        @pack_settings = {} of String => Hash(String, JSON::Any)
        @behavior_owners = {} of String => String
        @tool_owners = {} of String => String
        @policy_owners = {} of String => String
        @object_type_owners = {} of String => String
        @relation_type_owners = {} of String => String
        @behavior_short_to_canonical = {} of String => String
        @tool_short_to_canonical = {} of String => String
        @object_type_schemas = {} of String => (String -> String)
        @relation_type_specs = {} of String => RelationType
        @gated_object_types = {} of String => Array(String)
        @pack_pending_approvals = [] of PackPendingApproval
        @disabled_packs = Set(String).new
        @next_approval_n = 1
      end

      # A fork's runtime owns an independent pack snapshot: loading a pack on
      # the fork must never leak into the parent (mirrors activegraph, where a
      # fork's pack state is created fresh by load_pack). Shares the immutable
      # Pack/schema values; copies the mutable containers.
      def fork_snapshot : PackRuntimeState
        copy = PackRuntimeState.new
        copy.loaded_packs.merge!(@loaded_packs)
        copy.pack_settings.merge!(@pack_settings)
        copy.behavior_owners.merge!(@behavior_owners)
        copy.tool_owners.merge!(@tool_owners)
        copy.policy_owners.merge!(@policy_owners)
        copy.object_type_owners.merge!(@object_type_owners)
        copy.relation_type_owners.merge!(@relation_type_owners)
        copy.behavior_short_to_canonical.merge!(@behavior_short_to_canonical)
        copy.tool_short_to_canonical.merge!(@tool_short_to_canonical)
        copy.object_type_schemas.merge!(@object_type_schemas)
        copy.relation_type_specs.merge!(@relation_type_specs)
        copy.gated_object_types.merge!(@gated_object_types)
        copy.pack_pending_approvals.concat(@pack_pending_approvals)
        copy.disabled_packs.concat(@disabled_packs)
        copy.next_approval_n = @next_approval_n
        copy
      end
    end

    # Sentinel for a short name claimed by two packs.
    AMBIGUOUS = "<<AMBIGUOUS>>"

    # The pack loading lifecycle: conflict detection, namespace prefixing,
    # settings injection, schema attachment, and `pack.loaded` emission.
    # This is the implementation of `Runtime#load_pack` (mirrors
    # activegraph.packs.loader.load_pack_into_runtime).
    module Loader
      extend self

      # Returns True if the pack was newly loaded, False if it was already
      # loaded (idempotency).
      def load_pack_into_runtime(rt : Runtime(M), pack : Pack, settings : Hash(String, JSON::Any)? = nil) : Bool forall M
        state = rt.pack_state

        # ---- 1. idempotency / version conflict ---------------------------
        existing = state.loaded_packs[pack.name]?
        if existing
          return false if existing.version == pack.version
          raise PackVersionConflictError.new(
            "pack #{pack.name.inspect}: already loaded version #{existing.version.inspect}, " \
            "attempted to load version #{pack.version.inspect}"
          )
        end

        # ---- 2. settings -------------------------------------------------
        settings_obj = build_settings(pack, settings)

        # ---- 3. pre-emptive conflict detection (no mutation yet) ---------
        detect_conflicts(rt, pack, state)

        # ---- 4. mutate ----------------------------------------------------
        state.loaded_packs[pack.name] = pack
        state.pack_settings[pack.name] = settings_obj
        state.disabled_packs.delete(pack.name)

        canonical_behaviors = [] of PackBehavior
        pack.behaviors.each do |b|
          canonical = "#{pack.name}.#{b.name}"
          wrapped = b.canonicalize(pack, settings_obj)
          canonical_behaviors << wrapped
          state.behavior_owners[canonical] = pack.name
          add_short_name(state.behavior_short_to_canonical, b.name, canonical)
        end

        pack.tools.each do |tool|
          canonical = "#{pack.name}.#{tool.name}"
          renamed = tool.with_pack_prefix(pack.name, tool.name)
          rt.pack_tools << renamed
          state.tool_owners[canonical] = pack.name
          add_short_name(state.tool_short_to_canonical, tool.name, canonical)
        end

        pack.object_types.each do |object_type|
          state.object_type_owners[object_type.name] = pack.name
          if validator = object_type.validator
            state.object_type_schemas[object_type.name] = validator
          end
        end

        pack.relation_types.each do |relation_type|
          state.relation_type_owners[relation_type.name] = pack.name
          state.relation_type_specs[relation_type.name] = relation_type
        end

        pack.policies.each do |policy|
          canonical = "#{pack.name}.#{policy.name}"
          state.policy_owners[canonical] = pack.name
          policy.requires_approval.each do |type_name|
            gated = state.gated_object_types[type_name]? || [] of String
            state.gated_object_types[type_name] = gated + [canonical]
          end
        end

        rt.pack_behaviors.concat(canonical_behaviors)

        # Attach schema validators now so subsequent live add_object /
        # add_relation calls are gated (validation is post-load, not
        # retroactive — CONTRACT v0.9 #5).
        if graph = rt.graph
          install_graph_validators(graph, state)
        end

        # ---- 5. emit pack.loaded -----------------------------------------
        rt.record_pack_loaded(pack, settings_obj)

        true
      end

      def build_settings(pack : Pack, settings : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)
        input = settings.nil? ? nil : JSON::Any.new(settings)
        pack.settings_builder.call(input)
      end

      private def detect_conflicts(rt : Runtime(M), pack : Pack, state : PackRuntimeState) : Nil forall M
        pack.behaviors.each do |b|
          canonical = "#{pack.name}.#{b.name}"
          if owner = state.behavior_owners[canonical]?
            raise PackConflictError.new(
              "behavior name conflict: #{canonical.inspect} declared by both pack #{owner.inspect} and pack #{pack.name.inspect}"
            )
          end
        end
        pack.tools.each do |tool|
          canonical = "#{pack.name}.#{tool.name}"
          if owner = state.tool_owners[canonical]?
            raise PackConflictError.new(
              "tool name conflict: #{canonical.inspect} declared by both pack #{owner.inspect} and pack #{pack.name.inspect}"
            )
          end
        end
        pack.object_types.each do |object_type|
          if owner = state.object_type_owners[object_type.name]?
            raise PackConflictError.new(
              "object type conflict: #{object_type.name.inspect} is already provided by pack #{owner.inspect}; pack #{pack.name.inspect} also declares it"
            )
          end
        end
        pack.relation_types.each do |relation_type|
          if owner = state.relation_type_owners[relation_type.name]?
            raise PackConflictError.new(
              "relation type conflict: #{relation_type.name.inspect} is already provided by pack #{owner.inspect}; pack #{pack.name.inspect} also declares it"
            )
          end
        end
        pack.policies.each do |policy|
          canonical = "#{pack.name}.#{policy.name}"
          if owner = state.policy_owners[canonical]?
            raise PackConflictError.new(
              "policy name conflict: #{canonical.inspect} is already provided by pack #{owner.inspect}; pack #{pack.name.inspect} also declares it"
            )
          end
        end

        # Globally-exported tool short names must not collide with global
        # tools or other packs' globally-exported tools.
        pack.tools.each do |tool|
          next unless tool.export_globally?
          global_collision = ToolRegistry.snapshot.any? { |global_tool| global_tool.name == tool.name }
          pack_global_collision = rt.pack_tools.any? { |pack_tool| pack_tool.export_globally? && pack_tool.name == tool.name }
          if global_collision || pack_global_collision
            raise PackConflictError.new(
              "pack #{pack.name.inspect} declares tool #{tool.name.inspect} with export_globally=True, " \
              "but a tool by that name is already registered globally"
            )
          end
        end
      end

      def add_short_name(table : Hash(String, String), short : String, canonical : String) : Nil
        existing = table[short]?
        if existing.nil?
          table[short] = canonical
        elsif existing != canonical && existing != AMBIGUOUS
          table[short] = AMBIGUOUS
        end
      end

      def install_graph_validators(graph : GraphProjection, state : PackRuntimeState) : Nil
        graph.pack_object_validator = ->(object_type : String, data : String) : String {
          if validator = state.object_type_schemas[object_type]?
            begin
              validator.call(data)
            rescue ex : JSON::ParseException
              message = ex.message || "schema validation failed"
              raise PackSchemaViolation.for_object(object_type, message, state.object_type_owners[object_type]?)
            end
          else
            data
          end
        }
        graph.pack_relation_validator = ->(relation_type : String, source_type : String?, target_type : String?) : Nil {
          if spec = state.relation_type_specs[relation_type]?
            pack_name = state.relation_type_owners[relation_type]?
            if !spec.source_types.empty? && source_type && !spec.source_types.includes?(source_type)
              raise PackSchemaViolation.for_relation_source(relation_type, source_type, spec.source_types, pack_name)
            end
            if !spec.target_types.empty? && target_type && !spec.target_types.includes?(target_type)
              raise PackSchemaViolation.for_relation_target(relation_type, target_type, spec.target_types, pack_name)
            end
          end
        }
      end
    end
  end
end
