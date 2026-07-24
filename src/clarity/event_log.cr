require "set"

module Clarity
  # Append-only ordered storage for events accepted by the runtime boundary.
  class EventLog
    @events : Array(Event)
    @event_ids : Set(String)
    @last_sequence : UInt64?

    def initialize
      @events = [] of Event
      @event_ids = Set(String).new
      @last_sequence = nil
    end

    def append(event : Event) : Nil
      if last_sequence = @last_sequence
        if event.sequence <= last_sequence
          raise ArgumentError.new("event sequence must increase")
        end
      end

      if @event_ids.includes?(event.id)
        raise ArgumentError.new("event id must be unique")
      end

      @events << event
      @event_ids << event.id
      @last_sequence = event.sequence
    end

    # Returns a snapshot so callers cannot mutate the log's internal storage.
    def events : Array(Event)
      @events.dup
    end
  end
end
