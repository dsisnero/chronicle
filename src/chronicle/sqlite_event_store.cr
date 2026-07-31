require "json"
require "sqlite3"

module Chronicle
  # SQLite-backed event store for durable persistence.
  # Ported from activegraph.store.sqlite.SQLiteEventStore.
  #
  # Schema matches activegraph's design:
  #   events: seq, id, type, actor, payload, frame_id, caused_by, timestamp, run_id
  #   meta:   key, value (schema version)
  class SQLiteEventStore < EventStore
    getter db_path : String
    getter run_id : String
    @db : DB::Database

    MEMORY_PATH = ":memory:"

    def initialize(@db_path : String, @run_id : String)
      uri = @db_path == ":memory:" ? "sqlite3:///:memory:" : "sqlite3://#{@db_path}"
      @db = DB.open(uri)
      migrate
    end

    def append(event : Event) : Nil
      payload_json = event.payload
      @db.exec(
        "INSERT INTO events (id, type, actor, payload, caused_by, timestamp, run_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
        event.id, event.type, event.actor, payload_json, event.caused_by, event.timestamp.to_rfc3339, @run_id,
      )
    rescue error : SQLite3::Exception
      if error.message.try(&.includes?("UNIQUE constraint failed"))
        raise DuplicateEventError.new("duplicate event id: #{event.id}")
      end
      raise error
    end

    def iter_events(after : String? = nil, before : String? = nil) : Array(Event)
      sql = "SELECT seq, id, type, actor, payload, caused_by, timestamp FROM events WHERE run_id = ?"
      args = [@run_id] of DB::Any

      if after_id = after
        sql += " AND seq > (SELECT seq FROM events WHERE id = ? AND run_id = ?)"
        args << after_id << @run_id
      end
      if before_id = before
        sql += " AND seq <= (SELECT seq FROM events WHERE id = ? AND run_id = ?)"
        args << before_id << @run_id
      end

      sql += " ORDER BY seq"

      events = [] of Event
      @db.query(sql, args: args) do |result_set|
        result_set.each do
          seq = result_set.read(Int64).to_u64
          id = result_set.read(String)
          type = result_set.read(String)
          actor = result_set.read(String)
          payload = result_set.read(String)
          caused_by = result_set.read(String?)
          ts_str = result_set.read(String)
          ts = Time::Format::RFC_3339.parse(ts_str)

          events << Event.new(
            schema_version: 1_u16, sequence: seq, id: id,
            type: type, actor: actor, caused_by: caused_by,
            timestamp: ts, payload: payload,
          )
        end
      end
      events
    end

    def get_event(id : String) : Event?
      result = nil
      @db.query("SELECT seq, id, type, actor, payload, caused_by, timestamp FROM events WHERE id = ? AND run_id = ?", id, @run_id) do |result_set|
        result_set.each do
          seq = result_set.read(Int64).to_u64
          eid = result_set.read(String)
          type = result_set.read(String)
          actor = result_set.read(String)
          payload = result_set.read(String)
          caused_by = result_set.read(String?)
          ts_str = result_set.read(String)
          ts = Time::Format::RFC_3339.parse(ts_str)

          result = Event.new(
            schema_version: 1_u16, sequence: seq, id: eid,
            type: type, actor: actor, caused_by: caused_by,
            timestamp: ts, payload: payload,
          )
        end
      end
      result
    end

    def count : Int64
      @db.scalar("SELECT COUNT(*) FROM events WHERE run_id = ?", @run_id).as(Int64)
    end

    def truncate_after(event_id : String) : Nil
      @db.exec(
        "DELETE FROM events WHERE run_id = ? AND seq > (SELECT seq FROM events WHERE id = ? AND run_id = ?)",
        @run_id, event_id, @run_id,
      )
    end

    def close : Nil
      @db.close
    end

    private def migrate : Nil
      @db.exec("CREATE TABLE IF NOT EXISTS events (
        seq    INTEGER PRIMARY KEY AUTOINCREMENT,
        id     TEXT NOT NULL,
        type   TEXT NOT NULL,
        actor  TEXT,
        payload TEXT NOT NULL,
        frame_id TEXT,
        caused_by TEXT,
        timestamp TEXT NOT NULL,
        run_id TEXT NOT NULL,
        UNIQUE(id, run_id)
      )")
      @db.exec("CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )")
      @db.exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1')")
    end
  end
end
