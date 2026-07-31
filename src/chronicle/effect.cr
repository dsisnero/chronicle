module Chronicle
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

  # Ephemeral handoff from the log-primary core to the platform edge. The
  # persisted `llm.requested` event remains authoritative; this value carries
  # no credential, socket, or provider SDK object.
  struct ModelEffectRequest
    getter request_event_id : String
    getter effect : EffectRequest
    getter target : Routing::Target

    def initialize(@request_event_id : String, @effect : EffectRequest, @target : Routing::Target)
    end

    def request_hash : String
      @effect.content_hash
    end
  end

  # Normalized platform-edge outcome for a model request. Provider-specific
  # response objects remain at the edge; callers receive only portable turn
  # data needed to resume the durable agent state machine.
  struct ModelEffectResult
    getter request_event_id : String
    getter provider : String
    getter model : String
    getter content : String
    getter choice : Crig::OneOrMany(Crig::Completion::AssistantContent)
    getter input_tokens : Int32
    getter output_tokens : Int32
    getter message_id : String

    def initialize(
      @request_event_id : String,
      @provider : String,
      @model : String,
      @content : String,
      @input_tokens : Int32,
      @output_tokens : Int32,
      @message_id : String,
    )
      @choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(Crig::Completion::AssistantContent.text(@content))
    end

    def initialize(
      @request_event_id : String,
      @provider : String,
      @model : String,
      @content : String,
      @input_tokens : Int32,
      @output_tokens : Int32,
      @message_id : String,
      @choice : Crig::OneOrMany(Crig::Completion::AssistantContent),
    )
    end
  end
end
