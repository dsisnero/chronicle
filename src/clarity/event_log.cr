module Clarity
  # Append-only ordered storage for events accepted by the runtime boundary.
  class EventLog
    @events : Array(Event)
    @last_sequence : UInt64?

    def initialize
      @events = [] of Event
      @last_sequence = nil
    end

    def append(event : Event) : Nil
      if last_sequence = @last_sequence
        if event.sequence <= last_sequence
          raise ArgumentError.new("event sequence must increase")
        end
      end

      @events << event
      @last_sequence = event.sequence
    end

    # Returns a snapshot so callers cannot mutate the log's internal storage.
    def events : Array(Event)
      @events.dup
    end
  end
end
