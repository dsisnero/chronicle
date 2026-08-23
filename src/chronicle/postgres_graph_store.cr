require "db"
require "pg"

# PostgreSQL-backed materialized graph projection. JSON text is retained beside
# JSONB so callers receive the same raw JSON representation they supplied.
module Chronicle
  class PostgresGraphStore < GraphStore
    @db : DB::Database
    @closed = false

    def initialize(url : String, @namespace : String = "default")
      @db = DB.open(url)
      self.class.ensure_schema(@db)
    end

    def self.ensure_schema(db : DB::Database) : Nil
      db.exec("CREATE TABLE IF NOT EXISTS chronicle_graph_objects (
        namespace TEXT NOT NULL,
        id TEXT NOT NULL,
        type TEXT NOT NULL,
        json JSONB NOT NULL,
        json_raw TEXT NOT NULL,
        PRIMARY KEY(namespace, id)
      )")
      db.exec("CREATE INDEX IF NOT EXISTS idx_chronicle_graph_objects_type ON chronicle_graph_objects(namespace, type)")
      db.exec("CREATE TABLE IF NOT EXISTS chronicle_graph_relations (
        namespace TEXT NOT NULL,
        id TEXT NOT NULL,
        type TEXT NOT NULL,
        from_id TEXT NOT NULL,
        to_id TEXT NOT NULL,
        json JSONB NOT NULL,
        json_raw TEXT NOT NULL,
        PRIMARY KEY(namespace, id)
      )")
      db.exec("CREATE INDEX IF NOT EXISTS idx_chronicle_graph_relations_from ON chronicle_graph_relations(namespace, from_id)")
      db.exec("CREATE INDEX IF NOT EXISTS idx_chronicle_graph_relations_to ON chronicle_graph_relations(namespace, to_id)")
      db.exec("CREATE INDEX IF NOT EXISTS idx_chronicle_graph_relations_type ON chronicle_graph_relations(namespace, type)")
      db.exec("CREATE TABLE IF NOT EXISTS chronicle_graph_patches (
        namespace TEXT NOT NULL,
        id TEXT NOT NULL,
        json JSONB NOT NULL,
        json_raw TEXT NOT NULL,
        PRIMARY KEY(namespace, id)
      )")
    end

    def put_object(obj : GraphObject) : Nil
      raw = obj.to_json
      @db.exec(
        "INSERT INTO chronicle_graph_objects (namespace, id, type, json, json_raw) VALUES ($1, $2, $3, $4::jsonb, $5) " \
        "ON CONFLICT(namespace, id) DO UPDATE SET type = EXCLUDED.type, json = EXCLUDED.json, json_raw = EXCLUDED.json_raw",
        @namespace, obj.id, obj.type, raw, raw,
      )
    end

    def get_object(object_id : String) : GraphObject?
      @db.query_one?("SELECT json_raw FROM chronicle_graph_objects WHERE namespace = $1 AND id = $2", @namespace, object_id) do |rows|
        GraphObject.from_json(rows.read(String))
      end
    end

    def remove_object(object_id : String) : Nil
      @db.exec("DELETE FROM chronicle_graph_objects WHERE namespace = $1 AND id = $2", @namespace, object_id)
    end

    def all_objects : Array(GraphObject)
      read_objects("SELECT json_raw FROM chronicle_graph_objects WHERE namespace = $1 ORDER BY id", [@namespace] of DB::Any)
    end

    def put_relation(rel : GraphRelation) : Nil
      raw = rel.to_json
      @db.exec(
        "INSERT INTO chronicle_graph_relations (namespace, id, type, from_id, to_id, json, json_raw) VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7) " \
        "ON CONFLICT(namespace, id) DO UPDATE SET type = EXCLUDED.type, from_id = EXCLUDED.from_id, to_id = EXCLUDED.to_id, json = EXCLUDED.json, json_raw = EXCLUDED.json_raw",
        @namespace, rel.id, rel.type, rel.from_id, rel.to_id, raw, raw,
      )
    end

    def get_relation(relation_id : String) : GraphRelation?
      @db.query_one?("SELECT json_raw FROM chronicle_graph_relations WHERE namespace = $1 AND id = $2", @namespace, relation_id) do |rows|
        GraphRelation.from_json(rows.read(String))
      end
    end

    def remove_relation(relation_id : String) : Nil
      @db.exec("DELETE FROM chronicle_graph_relations WHERE namespace = $1 AND id = $2", @namespace, relation_id)
    end

    def all_relations : Array(GraphRelation)
      read_relations("SELECT json_raw FROM chronicle_graph_relations WHERE namespace = $1 ORDER BY id", [@namespace] of DB::Any)
    end

    def put_patch(patch : Patch) : Nil
      raw = patch.to_json
      @db.exec(
        "INSERT INTO chronicle_graph_patches (namespace, id, json, json_raw) VALUES ($1, $2, $3::jsonb, $4) " \
        "ON CONFLICT(namespace, id) DO UPDATE SET json = EXCLUDED.json, json_raw = EXCLUDED.json_raw",
        @namespace, patch.id, raw, raw,
      )
    end

    def get_patch(patch_id : String) : Patch?
      @db.query_one?("SELECT json_raw FROM chronicle_graph_patches WHERE namespace = $1 AND id = $2", @namespace, patch_id) do |rows|
        Patch.from_json(rows.read(String))
      end
    end

    def all_patches : Array(Patch)
      patches = [] of Patch
      @db.query("SELECT json_raw FROM chronicle_graph_patches WHERE namespace = $1 ORDER BY id", @namespace) do |rows|
        rows.each { patches << Patch.from_json(rows.read(String)) }
      end
      patches
    end

    def remove_patch(patch_id : String) : Nil
      @db.exec("DELETE FROM chronicle_graph_patches WHERE namespace = $1 AND id = $2", @namespace, patch_id)
    end

    # These overrides keep filtering in PostgreSQL rather than deserializing
    # the complete projection before applying the GraphStore query hooks.
    def find_objects(type : String? = nil) : Array(GraphObject)
      return all_objects if type.nil?

      read_objects(
        "SELECT json_raw FROM chronicle_graph_objects WHERE namespace = $1 AND type = $2 ORDER BY id",
        [@namespace, type] of DB::Any,
      )
    end

    def find_objects_in_types(types : Array(String)) : Array(GraphObject)
      return [] of GraphObject if types.empty?

      args = [@namespace] of DB::Any
      placeholders = types.map do |type|
        args << type
        "$#{args.size}"
      end
      read_objects(
        "SELECT json_raw FROM chronicle_graph_objects WHERE namespace = $1 AND type IN (#{placeholders.join(", ")}) ORDER BY id",
        args,
      )
    end

    def find_relations(source : String? = nil, target : String? = nil, type : String? = nil) : Array(GraphRelation)
      sql = "SELECT json_raw FROM chronicle_graph_relations WHERE namespace = $1"
      args = [@namespace] of DB::Any
      if source
        args << source
        sql += " AND from_id = $#{args.size}"
      end
      if target
        args << target
        sql += " AND to_id = $#{args.size}"
      end
      if type
        args << type
        sql += " AND type = $#{args.size}"
      end
      read_relations(sql + " ORDER BY id", args)
    end

    # The breadth-first frontier is evaluated in PostgreSQL. Placeholder
    # relation endpoints remain traversable, while only materialized objects
    # appear in the returned object list, matching GraphStore's base semantics.
    def neighborhood(object_id : String, depth : Int32 = 1) : {Array(GraphObject), Array(GraphRelation)}
      start = get_object(object_id)
      return {[] of GraphObject, [] of GraphRelation} if start.nil?
      return {[start], [] of GraphRelation} if depth < 1

      args = [@namespace, object_id, depth] of DB::Any
      cte = "WITH RECURSIVE walk(id, distance) AS (" \
            "SELECT $2::text, 0 UNION " \
            "SELECT CASE WHEN relation.from_id = walk.id THEN relation.to_id ELSE relation.from_id END, walk.distance + 1 " \
            "FROM walk JOIN chronicle_graph_relations relation ON relation.namespace = $1 " \
            "AND (relation.from_id = walk.id OR relation.to_id = walk.id) WHERE walk.distance < $3) "
      objects = read_objects(
        cte + "SELECT DISTINCT object.json_raw FROM chronicle_graph_objects object JOIN walk ON walk.id = object.id " \
              "WHERE object.namespace = $1 ORDER BY object.json_raw",
        args,
      )
      relations = read_relations(
        cte + "SELECT DISTINCT relation.json_raw FROM chronicle_graph_relations relation JOIN walk ON " \
              "relation.from_id = walk.id OR relation.to_id = walk.id WHERE relation.namespace = $1 AND walk.distance < $3 ORDER BY relation.json_raw",
        args,
      )
      {objects, relations}
    end

    def clear : Nil
      @db.exec("DELETE FROM chronicle_graph_objects WHERE namespace = $1", @namespace)
      @db.exec("DELETE FROM chronicle_graph_relations WHERE namespace = $1", @namespace)
      @db.exec("DELETE FROM chronicle_graph_patches WHERE namespace = $1", @namespace)
    end

    def close : Nil
      return if @closed

      @db.close
      @closed = true
    end

    private def read_objects(sql : String, args : Array(DB::Any)) : Array(GraphObject)
      objects = [] of GraphObject
      @db.query(sql, args: args) { |rows| rows.each { objects << GraphObject.from_json(rows.read(String)) } }
      objects
    end

    private def read_relations(sql : String, args : Array(DB::Any)) : Array(GraphRelation)
      relations = [] of GraphRelation
      @db.query(sql, args: args) { |rows| rows.each { relations << GraphRelation.from_json(rows.read(String)) } }
      relations
    end
  end
end
