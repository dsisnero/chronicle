module Clarity
  enum EffectKind
    Model
    Tool
  end

  # A side-effect request produced by the core for execution at the platform edge.
  struct EffectRequest
    getter id : String
    getter kind : EffectKind
    getter payload : String

    def initialize(@id : String, @kind : EffectKind, @payload : String)
    end

    def content_hash : String
      ContentHash.digest(@payload)
    end
  end

  # A recorded result supplied by the platform edge during replay or execution.
  struct EffectResult
    getter request_hash : String
    getter? success : Bool
    getter payload : String

    def initialize(@request_hash : String, @success : Bool, @payload : String)
    end
  end
end
