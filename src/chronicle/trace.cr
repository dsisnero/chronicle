require "json"

# Causal-chain audit. Ported from activegraph activegraph/trace/causal.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
# Walks back from an object through caused_by links until a goal.created
# (or an event with no parent).
module Chronicle
  module Trace
    extend self

    def causal_chain(events : Array(Event), graph : GraphProjection, object_id : String) : String
      obj = graph.get_object(object_id)
      return "(no such object: #{object_id})" if obj.nil?

      by_id = {} of String => Event
      events.each { |e| by_id[e.id] = e }

      created_by = events.find { |e| e.type == "object.created" && created_object?(e, object_id) }

      lines = ["#{obj.id} (#{obj.type})"]
      indent = "  "
      seen = Set(String).new
      cursor = created_by
      while cursor
        if seen.includes?(cursor.id)
          lines << "#{indent}← (cycle at #{cursor.id})"
          break
        end
        seen << cursor.id
        lines << "#{indent}← #{cursor.actor} (#{cursor.id}) #{cursor.type}"
        parent = cursor.caused_by
        break if parent.nil?

        cursor = by_id[parent]?
        indent += "  "
      end
      lines.join("\n")
    end

    private def created_object?(event : Event, object_id : String) : Bool
      payload = JSON.parse(event.payload).as_h
      payload["id"]?.try(&.as_s) == object_id
    rescue JSON::ParseException
      false
    end
  end

  # Read-only facade over a run's event log, exposed as `runtime.trace`
  # (v1.3 structured accessors). `events` returns the run's events in log
  # order (a copy — each carries the id `Runtime#fork`'s `at_event=` expects);
  # `failures` returns the `behavior.failed` events whose payloads carry
  # behavior/event_id/exception_type/message/traceback. Ported from
  # activegraph.trace.printer.Trace (named TraceFacade because Chronicle's
  # `Trace` module already owns causal_chain).
  class TraceFacade
    @store : EventStore

    def initialize(@store : EventStore)
    end

    # The run's events, in log order, as Event objects. A copy — mutating
    # the returned list changes nothing.
    def events : Array(Event)
      @store.iter_events.dup
    end

    # The run's `behavior.failed` events, in log order. Each payload carries
    # behavior, event_id, exception_type, message, and the full traceback.
    def failures : Array(Event)
      @store.iter_events.select { |event| event.type == "behavior.failed" }
    end
  end
end
