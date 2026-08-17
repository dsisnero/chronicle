require "deque"
require "json"

module Chronicle
  # The single in-process FIFO queue upstream dispatch drains
  # (runtime/queue.py, CONTRACT #10: no priority, no async). Chronicle's own
  # dispatch drains directly from the event store, so this is a parity shape —
  # push / pop / size / empty? with FIFO ordering, available for tests and
  # tools rather than wired into the dispatch path.
  class EventQueue
    @queue = Deque(Event).new

    # Append an event to the back of the queue.
    def push(event : Event) : Nil
      @queue.push(event)
    end

    # Remove and return the front event, or nil when the queue is empty.
    def pop : Event?
      @queue.shift?
    end

    # The number of queued events.
    def size : Int32
      @queue.size
    end

    # True when the queue holds no events.
    def empty? : Bool
      @queue.empty?
    end
  end
end
