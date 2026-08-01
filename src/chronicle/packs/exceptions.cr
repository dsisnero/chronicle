# Pack exception hierarchy. Ported from activegraph/packs/__init__.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
module Chronicle
  module Packs
    # Root pack error. Mirrors activegraph.errors.PackError.
    class PackError < Chronicle::DomainError
    end

    # A Pack(...) constructor argument failed validation. Raised at
    # construction time, not at load time.
    class PackValidationError < PackError
    end

    # Two loaded packs conflict on a declared identifier. Raised at
    # runtime.load_pack time, pre-mutation.
    class PackConflictError < PackError
    end

    # Same pack name loaded with two different versions. Pre-mutation.
    class PackVersionConflictError < PackError
    end

    # graph.add_object / graph.add_relation data failed schema validation
    # against a loaded pack's declared type.
    class PackSchemaViolation < PackError
      getter object_type : String?
      getter relation_type : String?
      getter pack_name : String?

      def initialize(message : String, @object_type : String? = nil, @relation_type : String? = nil, @pack_name : String? = nil)
        super(message)
      end

      def self.for_object(
        object_type : String,
        validation_error : String,
        pack_name : String? = nil,
      ) : PackSchemaViolation
        pack_clause = pack_name ? " (declared by pack #{pack_name.inspect})" : ""
        new(
          "object_type #{object_type.inspect}: schema validation failed#{pack_clause}\nValidation error:\n  #{validation_error}",
          object_type: object_type,
          pack_name: pack_name,
        )
      end

      def self.for_relation_source(
        relation_type : String,
        source_type : String,
        allowed : Array(String),
        pack_name : String? = nil,
      ) : PackSchemaViolation
        pack_clause = pack_name ? " (declared by pack #{pack_name.inspect})" : ""
        new(
          "relation_type #{relation_type.inspect}: source type #{source_type.inspect} not allowed#{pack_clause}; " \
          "allowed source types: #{allowed.join(", ")}",
          relation_type: relation_type,
          pack_name: pack_name,
        )
      end

      def self.for_relation_target(
        relation_type : String,
        target_type : String,
        allowed : Array(String),
        pack_name : String? = nil,
      ) : PackSchemaViolation
        pack_clause = pack_name ? " (declared by pack #{pack_name.inspect})" : ""
        new(
          "relation_type #{relation_type.inspect}: target type #{target_type.inspect} not allowed#{pack_clause}; " \
          "allowed target types: #{allowed.join(", ")}",
          relation_type: relation_type,
          pack_name: pack_name,
        )
      end
    end

    # runtime.load_pack called without settings= for a pack whose settings
    # schema requires values.
    class PackSettingsMissingError < PackError
    end

    # A prompt file is malformed, missing required frontmatter, or unreadable.
    class PackPromptLoadError < PackError
    end

    # load_by_name could not find an installed pack.
    class PackNotFoundError < PackError
      getter pack_name : String
      getter installed : Array(String)

      def initialize(@pack_name : String, @installed : Array(String) = [] of String)
        installed_list = @installed.empty? ? "(no packs installed)" : @installed.map(&.inspect).join(", ")
        super("no installed pack named #{@pack_name.inspect}; installed: #{installed_list}")
      end
    end

    # get_behavior short-name lookup was ambiguous.
    class AmbiguousBehaviorError < PackError
    end

    # get_behavior could not find a registered behavior.
    class BehaviorNotFoundError < PackError
      getter behavior_name : String

      def initialize(@behavior_name : String)
        super("no behavior registered as #{@behavior_name.inspect}")
      end
    end

    # A manifest failed validation. Carries every violation at once.
    class PackManifestError < PackError
      getter violations : Array(String)

      def initialize(source : String, @violations : Array(String))
        preview = @violations.first(12).map { |v| "    - #{v}" }.join("\n")
        more = @violations.size > 12 ? "\n    ... and #{@violations.size - 12} more" : ""
        super("#{@violations.size} manifest violation(s) in #{source}\n#{preview}#{more}")
      end
    end
  end
end
