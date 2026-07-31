require "json"

module Clarity
  enum PatchOp
    Create
    Update
    Replace
    Remove
  end

  enum PatchState
    Proposed
    Applied
    Rejected
  end

  # Provenance metadata on every object, relation, and patch.
  # Written by the runtime, never by behaviors.
  struct Provenance
    getter created_by : String
    getter caused_by_event : String?
    getter frame_id : String?

    def initialize(
      @created_by : String,
      @caused_by_event : String? = nil,
      @frame_id : String? = nil,
    )
    end
  end

  struct Patch
    getter id : String
    getter target : String
    getter op : PatchOp
    getter value : String
    getter expected_version : Int64
    getter proposed_by : String
    getter status : PatchState
    getter rejection_reason : String?
    getter provenance : Provenance?

    def initialize(
      @id : String,
      @target : String,
      @op : PatchOp,
      @value : String,
      @expected_version : Int64,
      @proposed_by : String,
      @status : PatchState = PatchState::Proposed,
      @rejection_reason : String? = nil,
      @provenance : Provenance? = nil,
    )
    end
  end

  struct GraphObject
    getter id : String
    getter type : String
    getter data : String
    getter version : Int64
    getter provenance : Provenance

    def initialize(
      @id : String,
      @type : String,
      @data : String,
      @version : Int64 = 1,
      @provenance : Provenance = Provenance.new(created_by: "event"),
    )
    end
  end

  struct GraphRelation
    getter id : String
    getter type : String
    getter from_id : String
    getter to_id : String
    getter provenance : Provenance

    def initialize(
      @id : String,
      @type : String,
      @from_id : String,
      @to_id : String,
      @provenance : Provenance = Provenance.new(created_by: "event"),
    )
    end
  end

  struct PatchResult
    getter patch : Patch
    getter graph : GraphProjection
    getter diff : String?

    def initialize(@patch : Patch, @graph : GraphProjection, @diff : String? = nil)
    end
  end

  struct GraphDiff
    getter added_object_ids : Array(String)
    getter removed_object_ids : Array(String)
    getter added_relation_ids : Array(String)
    getter removed_relation_ids : Array(String)
    getter added_patch_ids : Array(String)
    getter removed_patch_ids : Array(String)

    def initialize(
      @added_object_ids : Array(String),
      @removed_object_ids : Array(String),
      @added_relation_ids : Array(String),
      @removed_relation_ids : Array(String),
      @added_patch_ids : Array(String) = [] of String,
      @removed_patch_ids : Array(String) = [] of String,
    )
    end
  end

  # Pure graph state reconstructed from typed object and relation events.
  # State lives behind a GraphStore backend; the projection is copy-on-write,
  # so apply/patch operations produce independent snapshots.
  class GraphProjection
    WHERE_OPS = {
      ">"      => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?(">", a, b) { |sign| sign > 0 } },
      "<"      => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?("<", a, b) { |sign| sign < 0 } },
      ">="     => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?(">=", a, b) { |sign| sign >= 0 } },
      "<="     => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.ordered?("<=", a, b) { |sign| sign <= 0 } },
      "=="     => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.json_equal?(a, b) },
      "!="     => ->(a : JSON::Any, b : JSON::Any) { !JsonCompare.json_equal?(a, b) },
      "in"     => ->(a : JSON::Any, b : JSON::Any) { JsonCompare.in?(a, b) },
      "not in" => ->(a : JSON::Any, b : JSON::Any) { !JsonCompare.in?(a, b) },
    } of String => Proc(JSON::Any, JSON::Any, Bool)

    @store : GraphStore
    @patch_ids_by_target : Hash(String, Array(String))
    @applied_events : Array(Event)

    def initialize(
      @store : GraphStore = InMemoryGraphStore.new,
      @patch_ids_by_target = {} of String => Array(String),
      @applied_events = [] of Event,
    )
    end

    def self.empty : self
      new
    end

    def self.replay(events : Array(Event)) : self
      events.reduce(empty) { |projection, event| projection.apply(event) }
    end

    def all_objects : Array(GraphObject)
      @store.all_objects
    end

    def all_relations : Array(GraphRelation)
      @store.all_relations
    end

    def all_patches : Array(Patch)
      @store.all_patches
    end

    def get_object(id : String) : GraphObject?
      @store.get_object(id)
    end

    def get_relation(id : String) : GraphRelation?
      @store.get_relation(id)
    end

    def get_patch(id : String) : Patch?
      @store.get_patch(id)
    end

    # Canonical query API: objects filtered by `type` and/or a `where`
    # predicate. Ported from activegraph Graph.objects.
    def objects(
      type : String? = nil,
      where : Hash(String, JSON::Any)? = nil,
    ) : Array(GraphObject)
      @store.find_objects(type).select do |obj|
        where_filter = where
        where_filter.nil? || where_on_object(where_filter, obj)
      end
    end

    # Backward-compatible alias for #objects.
    def query(
      object_type : String? = nil,
      where : Hash(String, JSON::Any)? = nil,
    ) : Array(GraphObject)
      objects(type: object_type, where: where)
    end

    # Canonical relation filter API: source/target/type compose by AND.
    def relations(
      source : String? = nil,
      target : String? = nil,
      type : String? = nil,
    ) : Array(GraphRelation)
      @store.find_relations(source: source, target: target, type: type)
    end

    # Legacy (object_id, direction) alias for #relations. Unrecognized
    # directions keep the v0 quirk of ignoring object_id.
    def get_relations(
      object_id : String? = nil,
      type : String? = nil,
      direction : String = "both",
    ) : Array(GraphRelation)
      if object_id.nil?
        relations(type: type)
      elsif direction == "outgoing"
        relations(source: object_id, type: type)
      elsif direction == "incoming"
        relations(target: object_id, type: type)
      elsif direction == "both"
        relations(type: type).select { |relation| object_id.in?({relation.from_id, relation.to_id}) }
      else
        relations(type: type)
      end
    end

    # OR-of-types single-pass scan, used by the view builder.
    def objects_in_types(types : Array(String)) : Array(GraphObject)
      @store.find_objects_in_types(types)
    end

    def has_object_of_type(type : String) : Bool
      !@store.find_objects(type).empty?
    end

    # Undirected breadth-first walk from object_id out to `depth` edges.
    def neighborhood(object_id : String, depth : Int32 = 1) : {Array(GraphObject), Array(GraphRelation)}
      @store.neighborhood(object_id, depth)
    end

    def apply(event : Event) : self
      store = @store.snapshot
      patch_ids_by_target = @patch_ids_by_target.dup
      applied_events = @applied_events.dup
      applied_events << event
      payload = JSON.parse(event.payload).as_h
      provenance = Provenance.new(created_by: event.actor, caused_by_event: event.id)

      case event.type
      when "object.created", "object.patched"
        id = payload["id"].as_s
        object_type = payload["type"]?.try(&.as_s) || store.get_object(id).try(&.type)
        data = payload["data"].to_json
        version = payload["version"]?.try(&.as_i.to_i64) || store.get_object(id).try(&.version) || 1_i64
        unless object_type
          raise GraphProjectionError.new("object type must be present")
        end
        store.put_object(GraphObject.new(id, object_type, data, version, provenance))
      when "relation.created"
        id = payload["id"].as_s
        store.put_relation(GraphRelation.new(
          id, payload["type"].as_s,
          payload["from_id"].as_s, payload["to_id"].as_s,
          provenance,
        ))
      when "patch.proposed"
        patch_data = payload["patch"].as_h
        patch = parse_patch(patch_data, PatchState::Proposed)
        store.put_patch(patch)
        ids = patch_ids_by_target.fetch(patch.target, [] of String)
        patch_ids_by_target[patch.target] = ids + [patch.id]
      when "patch.applied"
        patch_data = payload["patch"].as_h
        target_id = payload["target"].as_s
        patch = parse_patch(patch_data, PatchState::Applied)
        store.put_patch(patch)
        if obj = store.get_object(target_id)
          store.put_object(GraphObject.new(obj.id, obj.type, patch.value, obj.version + 1, provenance))
        end
      when "patch.rejected"
        patch_data = payload["patch"].as_h
        patch = parse_patch(patch_data, PatchState::Rejected)
        store.put_patch(patch)
      end

      self.class.new(store, patch_ids_by_target, applied_events)
    rescue KeyError | JSON::ParseException
      raise GraphProjectionError.new("invalid graph event payload")
    end

    # Auto-apply shortcut: build patch, version-check, emit applied/rejected in one step.
    # Ported from activegraph.graph.Graph.patch_object.
    def patch_object(
      target : String,
      value : String,
      *,
      actor : String = "system",
      patch_id : String? = nil,
    ) : PatchResult
      obj = @store.get_object(target)
      raise GraphProjectionError.new("unknown object: #{target}") unless obj

      ver = obj.version
      id = patch_id || "patch_#{@store.all_patches.size + 1}"
      diff = compute_diff(obj.data, value)

      applied = Patch.new(
        id: id, target: target, op: PatchOp::Update,
        value: value, expected_version: ver,
        proposed_by: actor, status: PatchState::Applied,
      )

      store = @store.snapshot
      patch_ids_by_target = @patch_ids_by_target.dup
      applied_events = @applied_events.dup
      store.put_patch(applied)
      store.put_object(GraphObject.new(obj.id, obj.type, value, ver + 1))
      ids = patch_ids_by_target.fetch(target, [] of String)
      patch_ids_by_target[target] = ids + [id]

      graph = self.class.new(store, patch_ids_by_target, applied_events)
      PatchResult.new(patch: applied, graph: graph, diff: diff)
    end

    def build_view(spec : ViewSpec = ViewSpec.new) : View
      objs = @store.all_objects
      rels = @store.all_relations

      if types = spec.include_types
        type_set = types.to_set
        objs = objs.select { |obj| type_set.includes?(obj.type) }
      end

      if around = spec.around
        center = @store.get_object(around)
        objs = objs.select { |obj| obj.id == around } if center
      end

      recent = if spec.recent_events > 0
                 @applied_events.last(Math.min(spec.recent_events, @applied_events.size))
               else
                 [] of Event
               end

      View.new(objects: objs, relations: rels, events: recent)
    end

    def propose_patch(
      target : String,
      op : String,
      value : String,
      *,
      proposed_by : String = "system",
      expected_version : Int64? = nil,
      patch_id : String? = nil,
    ) : Patch
      obj = @store.get_object(target)
      ver = expected_version || obj.try(&.version) || 0_i64
      patch = Patch.new(
        id: patch_id || "patch_#{@store.all_patches.size + 1}",
        target: target, op: PatchOp.parse(op),
        value: value, expected_version: ver,
        proposed_by: proposed_by, status: PatchState::Proposed,
      )
      @store.put_patch(patch)
      ids = @patch_ids_by_target.fetch(target, [] of String)
      @patch_ids_by_target[target] = ids + [patch.id]
      patch
    end

    def apply_patch(patch_id : String) : self
      patch = @store.get_patch(patch_id)
      raise GraphProjectionError.new("unknown patch: #{patch_id}") unless patch
      raise GraphProjectionError.new("patch #{patch_id} already #{patch.status}") unless patch.status.proposed?

      store = @store.snapshot
      patch_ids_by_target = @patch_ids_by_target.dup

      obj = store.get_object(patch.target)
      current_version = obj.try(&.version) || 0_i64

      if current_version != patch.expected_version
        rejected = Patch.new(
          id: patch.id, target: patch.target, op: patch.op,
          value: patch.value, expected_version: patch.expected_version,
          proposed_by: patch.proposed_by,
          status: PatchState::Rejected,
          rejection_reason: "version mismatch: expected #{patch.expected_version}, got #{current_version}",
        )
        store.put_patch(rejected)
        return self.class.new(store, patch_ids_by_target)
      end

      applied = Patch.new(
        id: patch.id, target: patch.target, op: patch.op,
        value: patch.value, expected_version: patch.expected_version,
        proposed_by: patch.proposed_by, status: PatchState::Applied,
      )
      store.put_patch(applied)

      if obj
        store.put_object(GraphObject.new(obj.id, obj.type, patch.value, obj.version + 1))
      end

      self.class.new(store, patch_ids_by_target)
    end

    def reject_patch(patch_id : String, reason : String) : self
      patch = @store.get_patch(patch_id)
      raise GraphProjectionError.new("unknown patch: #{patch_id}") unless patch
      raise GraphProjectionError.new("patch #{patch_id} already #{patch.status}") unless patch.status.proposed?

      store = @store.snapshot
      patch_ids_by_target = @patch_ids_by_target.dup
      rejected = Patch.new(
        id: patch.id, target: patch.target, op: patch.op,
        value: patch.value, expected_version: patch.expected_version,
        proposed_by: patch.proposed_by,
        status: PatchState::Rejected,
        rejection_reason: reason,
      )
      store.put_patch(rejected)
      self.class.new(store, patch_ids_by_target)
    end

    # Delegate the structural chain walk to the GraphStore backend.
    def match_chain(node_types : Array(String?), rels : Array({String, String})) : Array(ChainMatch)
      @store.match_chain(node_types, rels)
    end

    def diff(other : GraphProjection) : GraphDiff
      GraphDiff.new(
        other.all_objects.map(&.id).reject { |id| !@store.get_object(id).nil? }.sort!,
        @store.all_objects.map(&.id).reject { |id| !other.get_object(id).nil? }.sort!,
        other.all_relations.map(&.id).reject { |id| !@store.get_relation(id).nil? }.sort!,
        @store.all_relations.map(&.id).reject { |id| !other.get_relation(id).nil? }.sort!,
        other.all_patches.map(&.id).reject { |id| !@store.get_patch(id).nil? }.sort!,
        @store.all_patches.map(&.id).reject { |id| !other.get_patch(id).nil? }.sort!,
      )
    end

    private def where_on_object(where : Hash(String, JSON::Any), obj : GraphObject) : Bool
      data = JsonCompare.object_data_hash(obj.data)
      root = JSON::Any.new(
        {
          "id"      => JSON::Any.new(obj.id),
          "type"    => JSON::Any.new(obj.type),
          "data"    => JSON::Any.new(data),
          "version" => JSON::Any.new(obj.version),
        }.merge(data)
      )
      where.each do |key, expected|
        actual = resolve_where_path(root, key.split('.'))
        if expected.raw.is_a?(Hash(String, JSON::Any))
          expected.raw.as(Hash(String, JSON::Any)).each do |op, value|
            fn = WHERE_OPS[op]?
            if fn.nil?
              raise GraphProjectionError.new("unknown where operator: #{op}")
            end
            return false unless fn.call(actual, value)
          end
        else
          return false unless JsonCompare.json_equal?(actual, expected)
        end
      end
      true
    end

    private def resolve_where_path(root : JSON::Any, path : Array(String)) : JSON::Any
      cur = root
      path.each do |segment|
        if cur.raw.is_a?(Hash(String, JSON::Any))
          cur = cur[segment]? || JSON::Any.new(nil)
        else
          return JSON::Any.new(nil)
        end
      end
      cur
    end

    private def compute_diff(old_data : String, new_value : String) : String?
      return nil if old_data == new_value
      # Simple field-level diff as JSON
      old_h = JSON.parse(old_data).as_h? || {} of String => JSON::Any
      new_h = JSON.parse(new_value).as_h? || {} of String => JSON::Any
      added = new_h.reject { |k, _| old_h.has_key?(k) }
      removed = old_h.reject { |k, _| new_h.has_key?(k) }
      changed = old_h.select { |k, v| new_h[k]? != v && new_h.has_key?(k) }

      JSON.build do |json|
        json.object do
          json.field "added", added
          json.field "removed", removed.keys
          json.field "changed" do
            json.object do
              changed.each do |k, v|
                json.field k do
                  json.object do
                    json.field "from", v
                    json.field "to", new_h[k]
                  end
                end
              end
            end
          end
        end
      end
    rescue JSON::ParseException
      nil
    end

    private def parse_patch(data : Hash(String, JSON::Any), status : PatchState) : Patch
      Patch.new(
        id: data["id"].as_s,
        target: data["target"].as_s,
        op: PatchOp.parse(data["op"].as_s),
        value: data["value"].to_json,
        expected_version: data["expected_version"].as_i64,
        proposed_by: data["proposed_by"].as_s,
        status: status,
        rejection_reason: data["rejection_reason"]?.try(&.as_s),
      )
    end
  end
end
