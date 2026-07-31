require "set"

# GraphStore: pluggable backend for the materialized graph state.
# Ported from activegraph activegraph/core/graph_store.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
#
# A GraphStore is the queryable current-state view rebuilt by replaying the
# event log; the EventStore is the durable, append-only log (source of truth).
# Losing a GraphStore is recoverable (replay the log); losing the EventStore
# is not. The projector is still the only writer.
#
# put_* is an upsert (insert or overwrite by id). get_* returns nil for unknown
# ids. remove_* is a no-op for unknown ids. The optional query hooks have
# working defaults over all_objects / all_relations, so the base class is the
# canonical definition of their semantics; a backend may override to push the
# work down, but MUST return exactly what the default would (order aside).
# Hooks use only Object/Relation attributes — never the WHERE predicate
# language — so backends stay decoupled from query-language details.
module Chronicle
  abstract class GraphStore
    # ---- objects ----

    abstract def put_object(obj : GraphObject) : Nil

    abstract def get_object(object_id : String) : GraphObject?

    abstract def remove_object(object_id : String) : Nil

    abstract def all_objects : Array(GraphObject)

    # ---- relations ----

    abstract def put_relation(rel : GraphRelation) : Nil

    abstract def get_relation(relation_id : String) : GraphRelation?

    abstract def remove_relation(relation_id : String) : Nil

    abstract def all_relations : Array(GraphRelation)

    # ---- patches ----

    abstract def put_patch(patch : Patch) : Nil

    abstract def get_patch(patch_id : String) : Patch?

    abstract def all_patches : Array(Patch)

    # Not part of the projector's hot path (patches are never deleted by events —
    # only superseded), but clear needs it.
    abstract def remove_patch(patch_id : String) : Nil

    # ---- query hooks (optional pushdown) ----

    def find_objects(type : String? = nil) : Array(GraphObject)
      if type.nil?
        all_objects
      else
        all_objects.select { |obj| obj.type == type }
      end
    end

    def find_objects_in_types(types : Array(String)) : Array(GraphObject)
      return [] of GraphObject if types.empty?
      type_set = types.to_set
      all_objects.select { |obj| type_set.includes?(obj.type) }
    end

    def find_relations(
      source : String? = nil,
      target : String? = nil,
      type : String? = nil,
    ) : Array(GraphRelation)
      all_relations.select do |relation|
        (source.nil? || relation.from_id == source) &&
          (target.nil? || relation.to_id == target) &&
          (type.nil? || relation.type == type)
      end
    end

    # Undirected breadth-first walk from object_id out to `depth` edges.
    # Returns {objects, relations}; the start is included, placeholder endpoints
    # that are not objects are skipped. Returns {[], []} if object_id is not an object.
    def neighborhood(object_id : String, depth : Int32 = 1) : {Array(GraphObject), Array(GraphRelation)}
      return {[] of GraphObject, [] of GraphRelation} if get_object(object_id).nil?
      seen_objects = Set(String).new
      seen_objects << object_id
      frontier = Set(String).new
      frontier << object_id
      seen_relations = Set(String).new
      depth.times do
        next_frontier = Set(String).new
        all_relations.each do |relation|
          if frontier.includes?(relation.from_id) || frontier.includes?(relation.to_id)
            seen_relations << relation.id
            next_frontier << relation.from_id unless seen_objects.includes?(relation.from_id)
            next_frontier << relation.to_id unless seen_objects.includes?(relation.to_id)
          end
        end
        seen_objects.concat(next_frontier)
        frontier = next_frontier
        break if frontier.empty?
      end
      objects = [] of GraphObject
      seen_objects.each { |id| if obj = get_object(id)
        objects << obj
      end }
      relations = [] of GraphRelation
      seen_relations.each { |id| if rel = get_relation(id)
        relations << rel
      end }
      {objects, relations}
    end

    # Enumerate every structural match of a linear node→rel→node chain.
    # node_types is one entry per node position (nil = any type); rels is one
    # (rel_type, direction) per hop, where direction is "right" or "left".
    # Semantics are homomorphic: a single object or relation may fill more than
    # one position. Only structural filters apply here; node {prop: value}
    # equality and WHERE are layered on by the PatternMatcher.
    def match_chain(node_types : Array(String?), rels : Array({String, String})) : Array(ChainMatch)
      return [] of ChainMatch if node_types.empty?
      results = [] of ChainMatch
      find_objects(node_types[0]).each do |seed|
        extend_chain_match(node_types, rels, [seed], [] of GraphRelation, results)
      end
      results
    end

    # ---- lifecycle ----

    def clear : Nil
      all_objects.each { |obj| remove_object(obj.id) }
      all_relations.each { |relation| remove_relation(relation.id) }
      all_patches.each { |patch| remove_patch(patch.id) }
    end

    def close : Nil
    end

    private def extend_chain_match(
      node_types : Array(String?),
      rels : Array({String, String}),
      objs : Array(GraphObject),
      rel_chain : Array(GraphRelation),
      results : Array(ChainMatch),
    ) : Nil
      i = objs.size - 1
      if i == rels.size
        results << ChainMatch.new(objects: objs.dup, relations: rel_chain.dup)
        return
      end
      rel_type, direction = rels[i]
      next_type = node_types[i + 1]
      src = objs.last
      if direction == "right"
        find_relations(source: src.id, type: rel_type).each do |relation|
          neighbor = get_object(relation.to_id)
          next if neighbor.nil?
          next if !next_type.nil? && neighbor.type != next_type
          extend_chain_match(node_types, rels, objs + [neighbor], rel_chain + [relation], results)
        end
      else
        find_relations(target: src.id, type: rel_type).each do |relation|
          neighbor = get_object(relation.from_id)
          next if neighbor.nil?
          next if !next_type.nil? && neighbor.type != next_type
          extend_chain_match(node_types, rels, objs + [neighbor], rel_chain + [relation], results)
        end
      end
    end
  end

  # Volatile, dict-backed GraphStore. The default backend.
  class InMemoryGraphStore < GraphStore
    @objects : Hash(String, GraphObject)
    @relations : Hash(String, GraphRelation)
    @patches : Hash(String, Patch)

    def initialize
      @objects = {} of String => GraphObject
      @relations = {} of String => GraphRelation
      @patches = {} of String => Patch
    end

    def put_object(obj : GraphObject) : Nil
      @objects[obj.id] = obj
    end

    def get_object(object_id : String) : GraphObject?
      @objects[object_id]?
    end

    def remove_object(object_id : String) : Nil
      @objects.delete(object_id)
    end

    def all_objects : Array(GraphObject)
      @objects.values
    end

    def put_relation(rel : GraphRelation) : Nil
      @relations[rel.id] = rel
    end

    def get_relation(relation_id : String) : GraphRelation?
      @relations[relation_id]?
    end

    def remove_relation(relation_id : String) : Nil
      @relations.delete(relation_id)
    end

    def all_relations : Array(GraphRelation)
      @relations.values
    end

    def put_patch(patch : Patch) : Nil
      @patches[patch.id] = patch
    end

    def get_patch(patch_id : String) : Patch?
      @patches[patch_id]?
    end

    def all_patches : Array(Patch)
      @patches.values
    end

    def remove_patch(patch_id : String) : Nil
      @patches.delete(patch_id)
    end

    def clear : Nil
      @objects.clear
      @relations.clear
      @patches.clear
    end
  end
end
