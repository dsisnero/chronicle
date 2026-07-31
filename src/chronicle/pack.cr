require "json"

# Pack bundle + per-behavior policy. Ported from activegraph
# activegraph/packs/__init__.py (Pack, PackPolicy) and activegraph/policy.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
module Chronicle
  # Declared write/tool allowlists for a behavior.
  struct Policy
    getter behavior : String?
    getter can_create : Array(String)
    getter can_create_relation : Array(String)
    getter can_call_tool : Array(String)
    getter requires_approval : Array(String)

    def initialize(
      @behavior : String? = nil,
      @can_create : Array(String) = [] of String,
      @can_create_relation : Array(String) = [] of String,
      @can_call_tool : Array(String) = [] of String,
      @requires_approval : Array(String) = [] of String,
    )
    end
  end

  # A bundle of object types, tools, behaviors, and policies for a domain.
  struct Pack
    getter name : String
    getter version : String
    getter description : String
    getter object_types : Array(String)
    getter relation_types : Array(String)
    getter tools : Array(Tool)
    getter policies : Array(Policy)

    def initialize(
      @name : String,
      @version : String,
      @description : String = "",
      @object_types : Array(String) = [] of String,
      @relation_types : Array(String) = [] of String,
      @tools : Array(Tool) = [] of Tool,
      @policies : Array(Policy) = [] of Policy,
    )
      unless @name.matches?(/^[a-z][a-z0-9_]*$/)
        raise PackError.new("Pack.name must match [a-z][a-z0-9_]*, got #{@name}")
      end
      raise PackError.new("Pack.version must be non-empty, got #{@version.inspect}") if @version.empty?
    end
  end
end
