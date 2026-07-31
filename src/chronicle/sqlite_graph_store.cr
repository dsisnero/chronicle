require "sqlite3"

# SQLite-backed GraphStore. Entities are stored as their JSON::Serializable
# representation in id-keyed rows; the base-class query hooks (find_objects,
# find_relations, neighborhood, match_chain) run over all_objects/all_relations.
module Chronicle
  class SQLiteGraphStore < GraphStore
    @db : DB::Database

    def initialize(path : String)
      uri = path == ":memory:" ? "sqlite3:///:memory:" : "sqlite3://#{path}"
      @db = DB.open(uri)
      @db.exec("CREATE TABLE IF NOT EXISTS graph_objects (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
      @db.exec("CREATE TABLE IF NOT EXISTS graph_relations (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
      @db.exec("CREATE TABLE IF NOT EXISTS graph_patches (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
    end

    def put_object(obj : GraphObject) : Nil
      @db.exec(
        "INSERT INTO graph_objects (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
        obj.id, obj.to_json,
      )
    end

    def get_object(object_id : String) : GraphObject?
      @db.query_one?("SELECT json FROM graph_objects WHERE id = ?", object_id) do |row_set|
        GraphObject.from_json(row_set.read(String))
      end
    end

    def remove_object(object_id : String) : Nil
      @db.exec("DELETE FROM graph_objects WHERE id = ?", object_id)
    end

    def all_objects : Array(GraphObject)
      objects = [] of GraphObject
      @db.query("SELECT json FROM graph_objects") do |row_set|
        row_set.each do
          objects << GraphObject.from_json(row_set.read(String))
        end
      end
      objects
    end

    def put_relation(rel : GraphRelation) : Nil
      @db.exec(
        "INSERT INTO graph_relations (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
        rel.id, rel.to_json,
      )
    end

    def get_relation(relation_id : String) : GraphRelation?
      @db.query_one?("SELECT json FROM graph_relations WHERE id = ?", relation_id) do |row_set|
        GraphRelation.from_json(row_set.read(String))
      end
    end

    def remove_relation(relation_id : String) : Nil
      @db.exec("DELETE FROM graph_relations WHERE id = ?", relation_id)
    end

    def all_relations : Array(GraphRelation)
      relations = [] of GraphRelation
      @db.query("SELECT json FROM graph_relations") do |row_set|
        row_set.each do
          relations << GraphRelation.from_json(row_set.read(String))
        end
      end
      relations
    end

    def put_patch(patch : Patch) : Nil
      @db.exec(
        "INSERT INTO graph_patches (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
        patch.id, patch.to_json,
      )
    end

    def get_patch(patch_id : String) : Patch?
      @db.query_one?("SELECT json FROM graph_patches WHERE id = ?", patch_id) do |row_set|
        Patch.from_json(row_set.read(String))
      end
    end

    def all_patches : Array(Patch)
      patches = [] of Patch
      @db.query("SELECT json FROM graph_patches") do |row_set|
        row_set.each do
          patches << Patch.from_json(row_set.read(String))
        end
      end
      patches
    end

    def remove_patch(patch_id : String) : Nil
      @db.exec("DELETE FROM graph_patches WHERE id = ?", patch_id)
    end

    def clear : Nil
      @db.exec("DELETE FROM graph_objects")
      @db.exec("DELETE FROM graph_relations")
      @db.exec("DELETE FROM graph_patches")
    end

    def close : Nil
      @db.close
    end
  end
end
