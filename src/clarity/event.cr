module Clarity
  # An immutable input to the log projection, supplied by the platform edge.
  struct Event
    getter schema_version : UInt16
    getter sequence : UInt64
    getter id : String
    getter type : String
    getter actor : String
    getter caused_by : String?
    getter timestamp : Time
    getter payload : String

    def initialize(
      @schema_version : UInt16,
      @sequence : UInt64,
      @id : String,
      @type : String,
      @actor : String,
      @caused_by : String?,
      @timestamp : Time,
      @payload : String,
    )
    end
  end
end
