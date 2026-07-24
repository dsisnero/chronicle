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
          raise EventSequenceError.new("event sequence must increase")
        end
      end

      if @event_ids.includes?(event.id)
        raise DuplicateEventError.new("event id must be unique")
      end

      if caused_by = event.caused_by
        unless @event_ids.includes?(caused_by)
          raise CausalParentError.new("caused_by event must exist")
        end
      end

      @events << event
      @event_ids << event.id
      @last_sequence = event.sequence
    end

    def fork_at(sequence : UInt64) : EventLog
      prefix = @events.take_while { |event| event.sequence <= sequence }
      self.class.from_events(prefix)
    end

    def self.from_events(events : Array(Event)) : EventLog
      log = new
      events.each { |event| log.append(event) }
      log
    end

    # Returns a snapshot so callers cannot mutate the log's internal storage.
    def events : Array(Event)
      @events.dup
    end
  end
end
