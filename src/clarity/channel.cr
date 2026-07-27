module Clarity
  # Channel-neutral commands submitted by presentation adapters.
  module Channel
    struct SendMessage
      getter command_id : String
      getter run_id : String
      getter content : String
      getter channel : String
      getter intent_hint : String?
      getter model_override : String?

      def initialize(
        @command_id : String,
        @run_id : String,
        @content : String,
        @channel : String,
        @intent_hint : String? = nil,
        @model_override : String? = nil,
      )
        raise ArgumentError.new("channel must be a stable adapter identifier") unless @channel.matches?(/\A[a-z][a-z0-9_-]*\z/)
      end
    end

    struct Acknowledgement
      getter command_id : String
      getter event_id : String
      getter? duplicate : Bool

      def initialize(@command_id : String, @event_id : String, @duplicate : Bool = false)
      end
    end
  end
end
