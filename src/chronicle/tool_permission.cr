module Chronicle
  # Tool permission checking based on Routing::PermissionMode.
  # Ported from smista.ai's tools.permissions allow/ask/deny model.
  module ToolPermission
    enum Result
      Allow
      Ask
      Deny
    end

    # Check if a tool is allowed, denied, or requires approval
    # based on the effective permissions from a routing decision.
    def self.check(
      tool_name : String,
      permissions : Hash(String, Routing::PermissionMode),
    ) : Result
      mode = permissions[tool_name]?
      case mode
      when Routing::PermissionMode::Allow
        Result::Allow
      when Routing::PermissionMode::Ask
        Result::Ask
      else
        Result::Deny
      end
    end

    # Tracks approval state for tools that require Ask.
    # In a real system this would integrate with the approval adapter
    # (Chronicle::ApprovalAdapter) or prompt the user via CLI.
    class Check
      def initialize
        @pending = {} of String => Bool
      end

      # Register a tool call requiring approval.
      def request(tool_name : String) : Nil
        @pending[tool_name] = false
      end

      # Approve a pending tool call.
      def approve(tool_name : String) : Nil
        @pending[tool_name] = true
      end

      # Reject a pending tool call.
      def reject(tool_name : String) : Nil
        @pending[tool_name] = false
      end

      # Check if a tool call was approved.
      def approved?(tool_name : String) : Bool
        @pending.fetch(tool_name, false)
      end
    end
  end
end
