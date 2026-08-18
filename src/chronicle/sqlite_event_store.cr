require "json"
require "sqlite3"

module Chronicle
  # SQLite-backed event store for durable persistence.
  # Ported from activegraph.store.sqlite.SQLiteEventStore.
  #
  # Schema matches activegraph's design:
  #   events: seq, id, type, actor, payload, frame_id, caused_by, timestamp, run_id
  #   runs:   run_id, parent_run_id, forked_at_event_id, label, created_at
  #   meta:   key, value (schema version)
  class SQLiteEventStore < EventStore
    getter db_path : String
    getter run_id : String
    @db : DB::Database

    MEMORY_PATH = ":memory:"

    # Run provenance/lineage record returned by `list_runs`. Ported from
    # activegraph.store.base.RunRecord.
    record RunRecord,
      run_id : String,
      parent_run_id : String?,
      forked_at_event_id : String?,
      label : String?,
      created_at : String

    # File-level helper: run SQLite `CREATE TABLE IF NOT EXISTS` for both the
    # events and runs tables, and set WAL + synchronous=NORMAL exactly like
    # activegraph's `_ensure_schema`. Mirrors the vendor's concurrency stance:
    # WAL lets a writer run while other connections keep reading the same file.
    def self.ensure_schema(conn : DB::Database) : Nil
      conn.exec("PRAGMA journal_mode=WAL")
      conn.exec("PRAGMA synchronous=NORMAL")
      conn.exec("CREATE TABLE IF NOT EXISTS events (
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
      conn.exec("CREATE TABLE IF NOT EXISTS runs (
        run_id TEXT PRIMARY KEY,
        parent_run_id TEXT,
        forked_at_event_id TEXT,
        label TEXT,
        created_at TEXT NOT NULL,
        goal TEXT,
        frame_id TEXT
      )")
      conn.exec("CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )")
      # v1.5 compaction (CONTRACT v1.5 #2): the archive tier and the snapshot
      # sidecar. Additive IF NOT EXISTS tables — old runtimes reading a new
      # file simply never touch them, so schema_version stays "1".
      conn.exec("CREATE TABLE IF NOT EXISTS events_archive (
        seq INTEGER,
        id TEXT NOT NULL,
        type TEXT NOT NULL,
        actor TEXT,
        payload TEXT NOT NULL,
        frame_id TEXT,
        caused_by TEXT,
        timestamp TEXT NOT NULL,
        run_id TEXT NOT NULL,
        archived_at TEXT NOT NULL,
        UNIQUE(id, run_id)
      )")
      conn.exec("CREATE INDEX IF NOT EXISTS idx_archive_run ON events_archive(run_id, seq)")
      conn.exec("CREATE TABLE IF NOT EXISTS snapshots (
        state_hash TEXT PRIMARY KEY,
        blob TEXT NOT NULL,
        created_at TEXT NOT NULL
      )")
    end

    def initialize(@db_path : String, @run_id : String)
      uri = @db_path == ":memory:" ? "sqlite3:///:memory:" : "sqlite3://#{@db_path}"
      @db = DB.open(uri)
      migrate
      upsert_run(created_at: Time.utc.to_rfc3339)
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

    # Insert or update this run's row. `nil` never clears a stored value
    # (v1.3 fix): re-opening a fork's store must not erase its parent/
    # forked_at/label lineage. Mirrors activegraph's `upsert_run`.
    def upsert_run(
      created_at : String,
      parent_run_id : String? = nil,
      forked_at_event_id : String? = nil,
      label : String? = nil,
      goal : String? = nil,
      frame_id : String? = nil,
    ) : Nil
      @db.exec(
        "INSERT INTO runs (run_id, parent_run_id, forked_at_event_id, label, created_at, goal, frame_id) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?) " \
        "ON CONFLICT(run_id) DO UPDATE SET " \
        "parent_run_id = COALESCE(excluded.parent_run_id, runs.parent_run_id), " \
        "forked_at_event_id = COALESCE(excluded.forked_at_event_id, runs.forked_at_event_id), " \
        "label = COALESCE(excluded.label, runs.label), " \
        "goal = COALESCE(excluded.goal, runs.goal), " \
        "frame_id = COALESCE(excluded.frame_id, runs.frame_id)",
        @run_id, parent_run_id, forked_at_event_id, label, created_at, goal, frame_id,
      )
    end

    # This run's lineage record, read live from the runs table. Ported from
    # activegraph's `SQLiteEventStore.get_run`.
    # ameba:disable Naming/AccessorMethodName
    def get_run : RunRecord?
      record = nil
      @db.query("SELECT run_id, parent_run_id, forked_at_event_id, label, created_at FROM runs WHERE run_id = ?", @run_id) do |result_set|
        result_set.each do
          record = RunRecord.new(
            run_id: result_set.read(String),
            parent_run_id: result_set.read(String?),
            forked_at_event_id: result_set.read(String?),
            label: result_set.read(String?),
            created_at: result_set.read(String),
          )
        end
      end
      record
    end

    # v1.5 compaction (CONTRACT v1.5 #2): snapshot + archive tier. Ported
    # from activegraph.store.sqlite.SQLiteEventStore.

    # Store a snapshot blob keyed by its state hash (idempotent).
    def put_snapshot(state_hash : String, blob : String, *, created_at : String) : Nil
      @db.exec(
        "INSERT OR REPLACE INTO snapshots(state_hash, blob, created_at) VALUES (?, ?, ?)",
        state_hash, blob, created_at,
      )
    end

    # The snapshot blob for `state_hash`, or nil.
    def get_snapshot(state_hash : String) : String?
      @db.query_one?("SELECT blob FROM snapshots WHERE state_hash = ?", state_hash, as: String)
    end

    # Move this run's rows with seq < `before_seq` to the archive tier, in one
    # transaction. Idempotent (re-running moves nothing). Returns rows moved.
    def archive_prefix(before_seq : Int64, *, archived_at : String) : Int32
      moved = 0_i64
      @db.transaction do |tx|
        result = tx.connection.exec(
          "INSERT OR IGNORE INTO events_archive " \
          "(seq, id, type, actor, payload, frame_id, caused_by, timestamp, run_id, archived_at) " \
          "SELECT seq, id, type, actor, payload, frame_id, caused_by, timestamp, run_id, ? FROM events " \
          "WHERE run_id = ? AND seq < ?",
          archived_at, @run_id, before_seq,
        )
        moved = result.rows_affected
        tx.connection.exec(
          "DELETE FROM events WHERE run_id = ? AND seq < ?",
          @run_id, before_seq,
        )
        tx.commit
      end
      moved.to_i
    end

    # Move ALL of this run's rows to the archive tier (retire).
    def archive_run(*, archived_at : String) : Int32
      archive_prefix(Int64::MAX, archived_at: archived_at)
    end

    # This run's archived events, in original seq order.
    def iter_archived : Array(Event)
      events = [] of Event
      @db.query("SELECT seq, id, type, actor, payload, caused_by, timestamp FROM events_archive WHERE run_id = ? ORDER BY seq", @run_id) do |result_set|
        result_set.each do
          seq = result_set.read(Int64).to_u64
          id = result_set.read(String)
          type = result_set.read(String)
          actor = result_set.read(String)
          payload = result_set.read(String)
          caused_by = result_set.read(String?)
          ts = Time::Format::RFC_3339.parse(result_set.read(String))
          events << Event.new(
            schema_version: 1_u16, sequence: seq, id: id,
            type: type, actor: actor, caused_by: caused_by,
            timestamp: ts, payload: payload,
          )
        end
      end
      events
    end

    # True when any of this run's events sit in the archive tier.
    def has_archived : Bool
      @db.query_one?("SELECT 1 FROM events_archive WHERE run_id = ? LIMIT 1", @run_id, as: Int32).is_a?(Int32)
    end

    # The `seq` of an event id in this run (upstream `_seq_of`). Raises
    # EventNotFoundError for an unknown id.
    def seq_of(event_id : String) : Int64
      @db.query_one?("SELECT seq FROM events WHERE id = ? AND run_id = ?", event_id, @run_id, as: Int64) ||
        raise EventNotFoundError.new("event #{event_id.inspect} not found in run #{@run_id.inspect}")
    end

    # File-level helper: every run's lineage row, in created order.
    # Mirrors activegraph's `SQLiteEventStore.list_runs`.
    def self.list_runs(path : String) : Array(RunRecord)
      records = [] of RunRecord
      conn = DB.open("sqlite3://#{path}")
      begin
        conn.exec("PRAGMA busy_timeout = 5000")
        ensure_schema(conn)
        conn.query("SELECT run_id, parent_run_id, forked_at_event_id, label, created_at FROM runs ORDER BY created_at") do |result_set|
          result_set.each do
            records << RunRecord.new(
              run_id: result_set.read(String),
              parent_run_id: result_set.read(String?),
              forked_at_event_id: result_set.read(String?),
              label: result_set.read(String?),
              created_at: result_set.read(String),
            )
          end
        end
      ensure
        conn.close
      end
      records
    end

    # File-level helper: copy events from parent_run_id up to and including
    # at_event_id into new_run_id and record the fork's lineage (CONTRACT
    # v0.5 #11: copy rows, no row-sharing). Returns the number of events
    # copied. Raises EventNotFoundError if at_event_id is not in the parent.
    def self.fork_run(
      path : String,
      parent_run_id : String,
      new_run_id : String,
      at_event_id : String,
      label : String?,
      created_at : String,
    ) : Int32
      conn = DB.open("sqlite3://#{path}")
      begin
        conn.exec("PRAGMA busy_timeout = 5000")
        ensure_schema(conn)
        cut = 0_i64
        found = false
        conn.query("SELECT seq FROM events WHERE id = ? AND run_id = ?", at_event_id, parent_run_id) do |result_set|
          result_set.each do
            cut = result_set.read(Int64)
            found = true
          end
        end
        unless found
          raise EventNotFoundError.new("event #{at_event_id.inspect} not found in run #{parent_run_id.inspect}")
        end

        parent_goal = nil
        parent_frame = nil
        conn.query("SELECT goal, frame_id FROM runs WHERE run_id = ?", parent_run_id) do |result_set|
          result_set.each do
            parent_goal = result_set.read(String?)
            parent_frame = result_set.read(String?)
          end
        end

        conn.exec(
          "INSERT INTO runs (run_id, parent_run_id, forked_at_event_id, label, created_at, goal, frame_id) " \
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
          new_run_id, parent_run_id, at_event_id, label, created_at, parent_goal, parent_frame,
        )

        copied = 0
        rows = [] of Tuple(String, String, String, String, String?, String?, String)
        conn.query("SELECT id, type, actor, payload, frame_id, caused_by, timestamp FROM events WHERE run_id = ? AND seq <= ? ORDER BY seq", parent_run_id, cut) do |result_set|
          result_set.each do
            rows << {
              result_set.read(String), result_set.read(String), result_set.read(String), result_set.read(String),
              result_set.read(String?), result_set.read(String?), result_set.read(String),
            }
          end
        end
        rows.each do |(eid, type, actor, payload, frame_id, caused_by, timestamp)|
          conn.exec(
            "INSERT INTO events (id, type, actor, payload, frame_id, caused_by, timestamp, run_id) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            eid, type, actor, payload, frame_id, caused_by, timestamp, new_run_id,
          )
          copied += 1
        end
        copied
      ensure
        conn.close
      end
    end

    private def migrate : Nil
      self.class.ensure_schema(@db)
      @db.exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1')")
    end
  end
end
