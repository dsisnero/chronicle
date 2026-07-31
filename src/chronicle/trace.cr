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
end
