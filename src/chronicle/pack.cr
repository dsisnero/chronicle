# Legacy per-behavior write/tool allowlist policy. Kept for backward
# compatibility with the runtime's tool-approval routing. The pack-system
# policy is `Chronicle::Packs::PackPolicy` (upstream `packs/__init__.py`).
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
end
