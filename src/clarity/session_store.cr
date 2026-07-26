require "file_utils"

module Clarity
  # Persists event logs to disk for replay, audit, and debugging.
  # Each session is stored as a newline-delimited JSON file in a
  # configurable directory.
  class SessionStore
    getter dir : String

    def initialize(@dir : String)
      Dir.mkdir_p(@dir) unless Dir.exists?(@dir)
    end

    # Save an event log and return the file path.
    def save(log : EventLog, session_name : String? = nil) : String
      name = session_name || timestamp_name
      path = File.join(@dir, "#{name}.log")
      encoded = EventLogCodec.encode(log)
      File.write(path, encoded)
      path
    end

    # Load an event log from a file path.
    def load(path : String) : EventLog
      content = File.read(path)
      EventLogCodec.decode(content)
    end

    # Load a file-backed MemoryEventStore for cursor-based access.
    def load_store(path : String) : MemoryEventStore
      log = load(path)
      store = MemoryEventStore.new
      log.events.each { |evt| store.append(evt) }
      store
    end

    # List all saved session file paths in the store directory.
    def list : Array(String)
      Dir.glob(File.join(@dir, "*.log")).sort
    end

    # Default session directory under the user's home.
    def self.default_dir : String
      home = ENV["HOME"]? || "."
      File.join(home, ".clarity", "sessions")
    end

    private def timestamp_name : String
      Time.utc.to_s("%Y%m%d_%H%M%S")
    end
  end
end
