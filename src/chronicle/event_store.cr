module Chronicle
  # Abstract interface for durable event storage.
  # Ported from activegraph.store.base.EventStore.
  abstract class EventStore
    # Append a single event to the store. The store is the sequencing
    # authority (upstream `seq` AUTOINCREMENT/BIGSERIAL): the persisted copy's
    # `sequence` is the store-assigned, strictly-increasing append position,
    # regardless of the emitter's provisional value.
    abstract def append(event : Event) : Nil

    # Iterate events, optionally bounded by event IDs.
    abstract def iter_events(after : String? = nil, before : String? = nil) : Array(Event)

    # Retrieve a specific event by ID.
    abstract def get_event(id : String) : Event?

    # Total number of events in the store.
    abstract def count : Int64

    # Delete all events after the specified event ID.
    abstract def truncate_after(event_id : String) : Nil

    # Close the store and release resources.
    abstract def close : Nil
  end

  # In-memory event store for testing and lightweight use.
  # Ported from activegraph.store.memory.InMemoryEventStore.
  class MemoryEventStore < EventStore
    def initialize
      @events = [] of Event
      @by_id = {} of String => Event
    end

    def append(event : Event) : Nil
      if @by_id.has_key?(event.id)
        raise DuplicateEventError.new("duplicate event id: #{event.id}")
      end
      stored = stamped(event, @events.size.to_u64 + 1)
      @events << stored
      @by_id[event.id] = stored
    end

    # The store is the sequencing authority, mirroring SQLite/Postgres
    # `seq` AUTOINCREMENT/BIGSERIAL. The emitter's provisional sequence is
    # replaced with the store-assigned append position so the log is always
    # strictly increasing and directly codec-encodable.
    private def stamped(event : Event, sequence : UInt64) : Event
      return event if event.sequence == sequence
      Event.new(
        schema_version: event.schema_version,
        sequence: sequence,
        id: event.id,
        type: event.type,
        actor: event.actor,
        caused_by: event.caused_by,
        payload: event.payload,
        frame_id: event.frame_id,
        timestamp: event.timestamp,
      )
    end

    def iter_events(after : String? = nil, before : String? = nil) : Array(Event)
      result = @events
      if after_id = after
        found = false
        result = result.select do |evt|
          if found
            true
          elsif evt.id == after_id
            found = true
            false
          else
            false
          end
        end
      end
      if before_id = before
        result = result.take_while { |evt| evt.id != before_id }.to_a
        if evt = @by_id[before_id]?
          result << evt
        end
      end
      result
    end

    def get_event(id : String) : Event?
      @by_id[id]?
    end

    def count : Int64
      @events.size.to_i64
    end

    def truncate_after(event_id : String) : Nil
      idx = @events.index { |evt| evt.id == event_id }
      return unless idx

      # Keep events up to and including the given ID
      to_keep = @events[0..idx]
      to_remove = @events[(idx + 1)..] || [] of Event

      @events = to_keep
      to_remove.each { |evt| @by_id.delete(evt.id) }
    end

    def close : Nil
    end
  end
end
