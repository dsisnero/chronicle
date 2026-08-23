require "db"
require "pg"

module Chronicle
  # PostgreSQL implementation of the durable event-store seam. It preserves
  # SQLite's per-run addressing, global append sequence, lineage records, and
  # transactional fork semantics while using PostgreSQL-native JSONB and
  # TIMESTAMPTZ columns. Ported from activegraph.store.postgres.
  class PostgresEventStore < EventStore
    SCHEMA_VERSION = "1"

    getter url : String
    getter run_id : String

    alias RunRecord = SQLiteEventStore::RunRecord

    @db : DB::Database
    @closed = false

    def initialize(@url : String, @run_id : String)
      @db = DB.open(url)
      self.class.ensure_schema(@db)
      upsert_run(created_at: Time.utc.to_rfc3339)
    end

    def self.ensure_schema(db : DB::Database) : Nil
      db.exec("CREATE TABLE IF NOT EXISTS events (
        seq BIGSERIAL PRIMARY KEY,
        id TEXT NOT NULL,
        type TEXT NOT NULL,
        actor TEXT,
        payload JSONB NOT NULL,
        payload_raw TEXT NOT NULL,
        frame_id TEXT,
        caused_by TEXT,
        timestamp TIMESTAMPTZ NOT NULL,
        run_id TEXT NOT NULL,
        UNIQUE(id, run_id)
      )")
      db.exec("CREATE INDEX IF NOT EXISTS idx_events_run ON events(run_id, seq)")
      db.exec("CREATE INDEX IF NOT EXISTS idx_events_type ON events(type)")
      db.exec("ALTER TABLE events ADD COLUMN IF NOT EXISTS payload_raw TEXT")
      db.exec("UPDATE events SET payload_raw = payload::text WHERE payload_raw IS NULL")
      db.exec("CREATE TABLE IF NOT EXISTS runs (
        run_id TEXT PRIMARY KEY,
        parent_run_id TEXT,
        forked_at_event_id TEXT,
        label TEXT,
        created_at TIMESTAMPTZ NOT NULL,
        goal TEXT,
        frame_id TEXT
      )")
      db.exec("CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )")
      db.exec("INSERT INTO meta(key, value) VALUES ('schema_version', $1) ON CONFLICT(key) DO NOTHING", SCHEMA_VERSION)
      version = db.query_one("SELECT value FROM meta WHERE key = 'schema_version'", as: String)
      raise IncompatibleRuntimeState.new("postgres store schema_version #{version.inspect} does not match #{SCHEMA_VERSION.inspect}") unless version == SCHEMA_VERSION
    end

    def append(event : Event) : Nil
      @db.exec(
        "INSERT INTO events (id, type, actor, payload, payload_raw, frame_id, caused_by, timestamp, run_id) " \
        "VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8, $9)",
        event.id, event.type, event.actor, event.payload, event.payload, event.frame_id,
        event.caused_by, event.timestamp.to_rfc3339, run_id,
      )
    rescue error : PQ::PQError
      raise DuplicateEventError.new("duplicate event id: #{event.id}") if error.message.try(&.includes?("duplicate key"))
      raise error
    end

    def iter_events(after : String? = nil, before : String? = nil) : Array(Event)
      sql = "SELECT seq, id, type, actor, payload_raw, frame_id, caused_by, " \
            "to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') FROM events WHERE run_id = $1"
      args = [run_id] of DB::Any
      if after_id = after
        sql += " AND seq > $#{args.size + 1}"
        args << seq_of(after_id)
      end
      if before_id = before
        sql += " AND seq <= $#{args.size + 1}"
        args << seq_of(before_id)
      end
      sql += " ORDER BY seq"
      events = [] of Event
      @db.query(sql, args: args) do |rows|
        rows.each { events << self.class.read_event(rows) }
      end
      events
    end

    def get_event(id : String) : Event?
      event = nil
      @db.query(
        "SELECT seq, id, type, actor, payload_raw, frame_id, caused_by, " \
        "to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') FROM events WHERE id = $1 AND run_id = $2",
        id, run_id,
      ) do |rows|
        rows.each { event = self.class.read_event(rows) }
      end
      event
    end

    def count : Int64
      @db.query_one("SELECT COUNT(*) FROM events WHERE run_id = $1", run_id, as: Int64)
    end

    def truncate_after(event_id : String) : Nil
      @db.exec("DELETE FROM events WHERE run_id = $1 AND seq > $2", run_id, seq_of(event_id))
    end

    def close : Nil
      return if @closed

      @db.close
      @closed = true
    end

    def seq_of(event_id : String) : Int64
      @db.query_one?("SELECT seq FROM events WHERE id = $1 AND run_id = $2", event_id, run_id, as: Int64) ||
        raise EventNotFoundError.new("event #{event_id.inspect} not found in run #{run_id.inspect}")
    end

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
        "VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT(run_id) DO UPDATE SET " \
        "parent_run_id = COALESCE(EXCLUDED.parent_run_id, runs.parent_run_id), " \
        "forked_at_event_id = COALESCE(EXCLUDED.forked_at_event_id, runs.forked_at_event_id), " \
        "label = COALESCE(EXCLUDED.label, runs.label), goal = COALESCE(EXCLUDED.goal, runs.goal), " \
        "frame_id = COALESCE(EXCLUDED.frame_id, runs.frame_id)",
        run_id, parent_run_id, forked_at_event_id, label, created_at, goal, frame_id,
      )
    end

    # ameba:disable Naming/AccessorMethodName
    def get_run : RunRecord?
      record = nil
      @db.query("SELECT run_id, parent_run_id, forked_at_event_id, label, created_at::text FROM runs WHERE run_id = $1", run_id) do |rows|
        rows.each { record = self.class.read_run(rows) }
      end
      record
    end

    def self.list_runs(url : String) : Array(RunRecord)
      result = with_database(url) do |db|
        records = [] of RunRecord
        db.query("SELECT run_id, parent_run_id, forked_at_event_id, label, created_at::text FROM runs ORDER BY created_at") do |rows|
          rows.each { records << read_run(rows) }
        end
        records
      end
      result.is_a?(Array(RunRecord)) ? result : raise RuntimeError.new("Postgres list_runs transaction returned no result")
    end

    def self.most_recent_run_id(url : String) : String?
      with_database(url) do |db|
        db.query_one?("SELECT runs.run_id FROM runs LEFT JOIN (SELECT run_id, MAX(seq) AS last_seq FROM events GROUP BY run_id) e ON e.run_id = runs.run_id ORDER BY (e.last_seq IS NULL), e.last_seq DESC, runs.created_at DESC LIMIT 1", as: String)
      end
    end

    def self.fork_run(url : String, *, parent_run_id : String, new_run_id : String, at_event_id : String, label : String?, created_at : String) : Int32
      result = with_database(url) do |db|
        db.transaction do |tx|
          conn = tx.connection
          cut = conn.query_one?("SELECT seq FROM events WHERE id = $1 AND run_id = $2", at_event_id, parent_run_id, as: Int64) ||
                raise EventNotFoundError.new("event #{at_event_id.inspect} not found in run #{parent_run_id.inspect}")
          parent = conn.query_one?("SELECT goal, frame_id FROM runs WHERE run_id = $1", parent_run_id, as: {String?, String?})
          goal = parent.try(&.[0])
          frame_id = parent.try(&.[1])
          conn.exec("INSERT INTO runs (run_id, parent_run_id, forked_at_event_id, label, created_at, goal, frame_id) VALUES ($1, $2, $3, $4, $5, $6, $7)", new_run_id, parent_run_id, at_event_id, label, created_at, goal, frame_id)
          inserted = conn.exec(
            "INSERT INTO events (id, type, actor, payload, payload_raw, frame_id, caused_by, timestamp, run_id) " \
            "SELECT id, type, actor, payload, payload_raw, frame_id, caused_by, timestamp, $1 FROM events " \
            "WHERE run_id = $2 AND seq <= $3 ORDER BY seq",
            new_run_id, parent_run_id, cut,
          )
          tx.commit
          inserted.rows_affected.to_i
        end
      end
      result.is_a?(Int32) ? result : raise RuntimeError.new("Postgres fork transaction returned no result")
    end

    private def self.with_database(url : String, &)
      db = DB.open(url)
      ensure_schema(db)
      yield db
    ensure
      db.close if db
    end

    def self.read_event(rows : DB::ResultSet) : Event
      Event.new(
        schema_version: 1_u16, sequence: rows.read(Int64).to_u64,
        id: rows.read(String), type: rows.read(String), actor: rows.read(String),
        payload: rows.read(String), frame_id: rows.read(String?), caused_by: rows.read(String?),
        timestamp: Time::Format::RFC_3339.parse(rows.read(String)),
      )
    end

    def self.read_run(rows : DB::ResultSet) : RunRecord
      RunRecord.new(
        run_id: rows.read(String), parent_run_id: rows.read(String?),
        forked_at_event_id: rows.read(String?), label: rows.read(String?), created_at: rows.read(String),
      )
    end
  end
end
