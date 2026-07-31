module Chronicle
  enum ApprovalKind
    FileWrite
    Shell
    Network
    RestrictedContext
  end

  struct ApprovalRequest
    getter id : String
    getter kind : ApprovalKind
    getter summary : String

    def initialize(@id : String, @kind : ApprovalKind, @summary : String)
    end
  end

  struct ApprovalDecision
    getter request_id : String
    getter? approved : Bool

    def initialize(@request_id : String, @approved : Bool)
    end
  end

  struct ApprovalResult
    getter request : ApprovalRequest
    getter? approved : Bool

    def initialize(@request : ApprovalRequest, @approved : Bool)
    end
  end

  # Edge-owned approval state for actions that require user confirmation.
  class ApprovalAdapter
    @pending = {} of String => ApprovalRequest

    def pending_requests : Array(ApprovalRequest)
      @pending.values
    end

    def request(request : ApprovalRequest) : Nil
      raise ApprovalError.new("approval request already exists") if @pending.has_key?(request.id)

      @pending[request.id] = request
    end

    def resolve(decision : ApprovalDecision) : ApprovalResult
      request = @pending.delete(decision.request_id)
      raise ApprovalError.new("approval request not found") unless request

      ApprovalResult.new(request, decision.approved?)
    end
  end
end
