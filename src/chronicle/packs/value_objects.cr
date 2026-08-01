module Chronicle
  module Packs
    PACK_NAME_RE = /^[a-z][a-z0-9_]*$/

    # A typed object the pack contributes. `validator` (when present) parses
    # and normalizes data JSON against the pack's schema; the loader attaches
    # it to the graph so `add_object` validates (objects created BEFORE the
    # pack loads are not retroactively validated — CONTRACT v0.9 #5).
    struct ObjectType
      getter name : String
      getter description : String
      getter validator : (String -> String)?

      def initialize(
        @name : String,
        @description : String = "",
        @validator : (String -> String)? = nil,
      )
        raise PackValidationError.new("ObjectType.name must be non-empty str, got #{@name.inspect}") if @name.empty?
      end
    end

    # A typed relation the pack contributes. `source_types` / `target_types`
    # constrain which object types each endpoint may be; empty means "any".
    struct RelationType
      getter name : String
      getter source_types : Array(String)
      getter target_types : Array(String)
      getter description : String

      def initialize(
        @name : String,
        @source_types : Array(String) = [] of String,
        @target_types : Array(String) = [] of String,
        @description : String = "",
      )
        raise PackValidationError.new("RelationType.name must be non-empty str, got #{@name.inspect}") if @name.empty?
      end
    end

    # A policy declared by a pack. `requires_approval` is a list of object type
    # names whose `add_object` is gated until `runtime.approve(...)` is called.
    struct PackPolicy
      getter name : String
      getter requires_approval : Array(String)
      getter auto_apply : Array(String)

      def initialize(
        @name : String,
        @requires_approval : Array(String) = [] of String,
        @auto_apply : Array(String) = [] of String,
      )
        raise PackValidationError.new("PackPolicy.name must be non-empty str, got #{@name.inspect}") if @name.empty?
      end
    end

    # One declared gateway capability: a provider capability this pack's host
    # wiring registers, with its risk class and optional canonical action class
    # (R0|R1|R2|R3|R4; undeclared when ""). Never derived from risk_class.
    struct CapabilityDecl
      getter provider : String
      getter capability : String
      getter risk_class : String
      getter credential_ref : String
      getter action_class : String

      def initialize(
        @provider : String,
        @capability : String,
        @risk_class : String,
        @credential_ref : String = "",
        @action_class : String = "",
      )
      end
    end

    RISK_CLASSES   = Set{"low", "medium", "high", "critical"}
    ACTION_CLASSES = Set{"R0", "R1", "R2", "R3", "R4"}

    DEFAULT_SETTINGS_BUILDER = ->(_input : JSON::Any?) : Hash(String, JSON::Any) { {} of String => JSON::Any }

    # A frozen bundle of pack contents. Equality and hashing are by
    # (name, version), not deep field comparison — that is what idempotent
    # loading hinges on (CONTRACT v0.9 #2 / #6).
    struct Pack
      getter name : String
      getter version : String
      getter description : String
      getter object_types : Array(ObjectType)
      getter relation_types : Array(RelationType)
      getter behaviors : Array(PackBehavior)
      getter tools : Array(Tool)
      getter policies : Array(PackPolicy)
      getter prompts : Array(PackPrompt)
      getter settings_schema : String
      getter settings_builder : Proc(JSON::Any?, Hash(String, JSON::Any))
      getter capabilities : Array(CapabilityDecl)

      def initialize(
        @name : String,
        @version : String,
        @description : String = "",
        @object_types : Array(ObjectType) = [] of ObjectType,
        @relation_types : Array(RelationType) = [] of RelationType,
        @behaviors : Array(PackBehavior) = [] of PackBehavior,
        @tools : Array(Tool) = [] of Tool,
        @policies : Array(PackPolicy) = [] of PackPolicy,
        @prompts : Array(PackPrompt) = [] of PackPrompt,
        @settings_schema : String = "EmptySettings",
        @settings_builder : Proc(JSON::Any?, Hash(String, JSON::Any)) = DEFAULT_SETTINGS_BUILDER,
        @capabilities : Array(CapabilityDecl) = [] of CapabilityDecl,
      )
        unless @name.matches?(PACK_NAME_RE)
          raise PackValidationError.new("Pack.name must match [a-z][a-z0-9_]*, got #{@name.inspect}")
        end
        raise PackValidationError.new("Pack.version must be non-empty str, got #{@version.inspect}") if @version.empty?

        check_unique(@object_types.map(&.name), "object type", @name)
        check_unique(@relation_types.map(&.name), "relation type", @name)
        check_unique(@behaviors.map(&.name), "behavior", @name)
        check_unique(@tools.map(&.name), "tool", @name)
        check_unique(@policies.map(&.name), "policy", @name)
        check_unique(@prompts.map(&.name), "prompt", @name)

        @behaviors.each do |b|
          unless b.is_a?(PackBehavior)
            raise PackValidationError.new(
              "Pack #{@name.inspect}: behavior #{b.inspect} is not a PackBehavior instance"
            )
          end
        end
        @tools.each do |tool|
          unless tool.is_a?(Tool)
            raise PackValidationError.new("Pack #{@name.inspect}: tool #{tool.inspect} is not a Tool instance")
          end
        end
        @capabilities.each do |capability|
          unless capability.is_a?(CapabilityDecl)
            raise PackValidationError.new(
              "Pack #{@name.inspect}: capabilities entries must be CapabilityDecl, got #{capability.inspect}"
            )
          end
          unless RISK_CLASSES.includes?(capability.risk_class)
            raise PackValidationError.new(
              "Pack #{@name.inspect}: capability #{capability.provider}.#{capability.capability} has risk_class " \
              "#{capability.risk_class.inspect}; must be one of low|medium|high|critical"
            )
          end
          unless capability.action_class.empty? || ACTION_CLASSES.includes?(capability.action_class)
            raise PackValidationError.new(
              "Pack #{@name.inspect}: capability #{capability.provider}.#{capability.capability} has action_class " \
              "#{capability.action_class.inspect}; must be one of R0|R1|R2|R3|R4 (or omitted)"
            )
          end
        end
        check_unique(@capabilities.map { |capability| "#{capability.provider}.#{capability.capability}" }, "capability", @name)
      end

      # Identity by (name, version).
      def ==(other : Pack) : Bool
        name == other.name && version == other.version
      end

      def hash(hasher)
        hasher.string(name)
        hasher.string(version)
        hasher
      end

      def prompt_manifest : Hash(String, Hash(String, String))
        @prompts.to_h { |prompt| {prompt.name, {"version" => prompt.version, "hash" => prompt.content_hash}} }
      end

      private def check_unique(names : Array(String), kind : String, pack_name : String) : Nil
        seen = Set(String).new
        names.each do |name|
          if seen.includes?(name)
            raise PackValidationError.new("Pack #{pack_name.inspect}: duplicate #{kind} name #{name.inspect}")
          end
          seen.add(name)
        end
      end
    end
  end

  # Backward-compatible top-level alias for the pack-system Pack.
  alias Pack = Packs::Pack
end
