module Chronicle
  # Content-addressed cache for tool results keyed by tool name + args hash.
  # Ported from activegraph's ToolCache pattern (tool.requested/tool.responded).
  class ToolCache
    def initialize
      @entries = {} of String => String
    end

    def size : Int32
      @entries.size
    end

    # Generate a cache key from tool name and canonical args.
    def self.key(tool_name : String, args : String) : String
      ContentHash.digest("#{tool_name}|#{args}")
    end

    # Retrieve a cached tool result. Returns nil on miss.
    def get(tool_name : String, args : String) : String?
      @entries[self.class.key(tool_name, args)]?
    end

    # Record a tool result. Overwrites on collision.
    def record(tool_name : String, args : String, output : String) : Nil
      @entries[self.class.key(tool_name, args)] = output
    end

    # Bulk-populate from tool.responded events.
    # Walks the log pairing tool.responded.caused_by back to
    # tool.requested to find tool name + args.
    def self.from_events(events : Array(Event)) : self
      cache = new
      by_id = {} of String => Event
      events.each { |e| by_id[e.id] = e }

      events.each do |evt|
        next unless evt.type == "tool.responded"

        payload = JSON.parse(evt.payload).as_h
        next if payload.has_key?("error")

        tool_name = payload["tool"]?.try(&.as_s)
        args = payload["args"]?.try(&.to_json)
        output = payload["output"]?.try(&.to_json)

        next unless tool_name && args && output

        cache.record(tool_name, args, output)
      end
      cache
    rescue JSON::ParseException
      ToolCache.new
    end
  end
end
