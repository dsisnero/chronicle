require "set"

module Chronicle
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

    # Number of appended events. Mirrors the EventStore protocol's `count`.
    def count : Int64
      @events.size.to_i64
    end

    # Look up an appended event by id, or nil. Mirrors `EventStore#get_event`.
    def get_event(id : String) : Event?
      @events.find { |event| event.id == id }
    end

    # All appended events in log order. Mirrors `EventStore#iter_events`.
    def iter_events : Array(Event)
      @events.dup
    end

    # Drop every event after `event_id`, keeping `event_id` and everything
    # before it. Unknown ids truncate nothing (mirrors `EventStore#truncate_after`).
    def truncate_after(event_id : String) : Nil
      index = @events.index { |event| event.id == event_id }
      return if index.nil?

      dropped = @events[(index + 1)..]
      dropped.each { |event| @event_ids.delete(event.id) }
      @events = @events[0..index]
      @last_sequence = @events.empty? ? nil : @events.last.sequence
    end

    # Returns a snapshot so callers cannot mutate the log's internal storage.
    def events : Array(Event)
      @events.dup
    end
  end
end
