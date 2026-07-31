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
    include JSON::Serializable

    @[JSON::Field(emit_null: true)]
    getter created_by : String
    @[JSON::Field(emit_null: true)]
    getter caused_by_event : String?
    @[JSON::Field(emit_null: true)]
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
    include JSON::Serializable

    getter id : String
    getter type : String
    @[JSON::Field(converter: Clarity::RawJSON)]
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
    include JSON::Serializable

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

    RESERVED_DATA_FIELDS = %w(provenance)

    @store : GraphStore
    @patch_ids_by_target : Hash(String, Array(String))
    @applied_events : Array(Event)
    @ids : IDGen
    @clock : Clock
    @event_store : EventStore?
    @listeners : Array(Proc(Event, Nil))
    @sinks : Hash(String, SinkHandle)

    def initialize(
      @store : GraphStore = InMemoryGraphStore.new,
      @patch_ids_by_target = {} of String => Array(String),
      @applied_events = [] of Event,
      @ids : IDGen = IDGen.new,
      @clock : Clock = WallClock.new,
      @event_store : EventStore? = nil,
      @listeners : Array(Proc(Event, Nil)) = [] of Proc(Event, Nil),
    )
      @sinks = {} of String => SinkHandle
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
      @applied_events << event
      payload = JSON.parse(event.payload).as_h
      provenance = Provenance.new(created_by: event.actor, caused_by_event: event.id)

      case event.type
      when "object.created", "object.patched"
        project_object!(payload, provenance)
      when "relation.created"
        id = payload["id"].as_s
        @store.put_relation(GraphRelation.new(
          id, payload["type"].as_s,
          payload["from_id"].as_s, payload["to_id"].as_s,
          provenance,
        ))
      when "object.removed"
        remove_object_from_state!(payload["id"].as_s)
      when "relation.removed"
        @store.remove_relation(payload["id"].as_s)
      when "patch.proposed"
        patch_data = payload["patch"].as_h
        patch = parse_patch(patch_data, PatchState::Proposed)
        @store.put_patch(patch)
        ids = @patch_ids_by_target.fetch(patch.target, [] of String)
        @patch_ids_by_target[patch.target] = ids + [patch.id]
      when "patch.applied"
        patch_data = payload["patch"].as_h
        target_id = payload["target"].as_s
        patch = parse_patch(patch_data, PatchState::Applied)
        @store.put_patch(patch)
        if obj = @store.get_object(target_id)
          @store.put_object(GraphObject.new(obj.id, obj.type, patch.value, obj.version + 1, provenance))
        end
      when "patch.rejected"
        patch_data = payload["patch"].as_h
        patch = parse_patch(patch_data, PatchState::Rejected)
        @store.put_patch(patch)
      end

      self
    rescue KeyError | JSON::ParseException
      raise GraphProjectionError.new("invalid graph event payload")
    end

    # Append, project, persist, then notify listeners. The only live mutator.
    def emit(event : Event) : Event
      apply(event)
      @event_store.try(&.append(event))
      @sinks.each_value(&.offer(event))
      @listeners.each(&.call(event))
      event
    end

    def add_sink(
      sink : Sink,
      name : String? = nil,
      queue_capacity : Int32 = 1024,
      overflow_policy : OverflowPolicy = OverflowPolicy::DropNewest,
    ) : String
      sink_name = name || sink.class.to_s.split("::").last
      @sinks[sink_name] = SinkHandle.new(
        sink, sink_name, "default",
        queue_capacity: queue_capacity, overflow_policy: overflow_policy,
      )
      sink.open
      sink_name
    end

    def remove_sink(name : String) : Nil
      if handle = @sinks.delete(name)
        handle.close
      end
    end

    def flush_sinks : Nil
      @sinks.each_value(&.flush)
    end

    def sink_statuses : Hash(String, SinkStatus)
      @sinks.to_h { |name, handle| {name, handle.status} }
    end

    def events : Array(Event)
      @applied_events
    end

    def attach_store(event_store : EventStore) : self
      @event_store = event_store
      self
    end

    def add_listener(listener : Proc(Event, Nil)) : Nil
      @listeners << listener
    end

    def remove_listener(listener : Proc(Event, Nil)) : Bool
      before = @listeners.size
      @listeners.delete(listener)
      @listeners.size != before
    end

    # Builds an object.created event and emits it. Returns the projected object.
    def add_object(
      type : String,
      data : String,
      *,
      actor : String = "system",
      caused_by : String? = nil,
    ) : GraphObject
      reject_reserved_fields!(data)
      object_id = @ids.object(type)
      emit(build_event("object.created", object_created_payload(object_id, type, data), actor, caused_by))
      get_object(object_id) || raise GraphProjectionError.new("object #{object_id} was not projected")
    end

    # Builds a relation.created event and emits it. Returns the projected relation.
    def add_relation(
      source : String,
      target : String,
      type : String,
      data : String = "{}",
      *,
      actor : String = "system",
      caused_by : String? = nil,
    ) : GraphRelation
      reject_reserved_fields!(data)
      relation_id = @ids.relation
      emit(build_event("relation.created", relation_created_payload(relation_id, type, source, target, data), actor, caused_by))
      get_relation(relation_id) || raise GraphProjectionError.new("relation #{relation_id} was not projected")
    end

    def remove_object(object_id : String, *, actor : String = "system", caused_by : String? = nil) : Nil
      return if get_object(object_id).nil?
      emit(build_event("object.removed", id_payload(object_id), actor, caused_by))
    end

    def remove_relation(relation_id : String, *, actor : String = "system", caused_by : String? = nil) : Nil
      return if get_relation(relation_id).nil?
      emit(build_event("relation.removed", id_payload(relation_id), actor, caused_by))
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

      @store.put_patch(applied)
      @store.put_object(GraphObject.new(obj.id, obj.type, value, ver + 1))
      ids = @patch_ids_by_target.fetch(target, [] of String)
      @patch_ids_by_target[target] = ids + [id]

      PatchResult.new(patch: applied, graph: self, diff: diff)
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

      obj = @store.get_object(patch.target)
      current_version = obj.try(&.version) || 0_i64

      if current_version != patch.expected_version
        rejected = Patch.new(
          id: patch.id, target: patch.target, op: patch.op,
          value: patch.value, expected_version: patch.expected_version,
          proposed_by: patch.proposed_by,
          status: PatchState::Rejected,
          rejection_reason: "version mismatch: expected #{patch.expected_version}, got #{current_version}",
        )
        @store.put_patch(rejected)
        return self
      end

      applied = Patch.new(
        id: patch.id, target: patch.target, op: patch.op,
        value: patch.value, expected_version: patch.expected_version,
        proposed_by: patch.proposed_by, status: PatchState::Applied,
      )
      @store.put_patch(applied)

      if obj
        @store.put_object(GraphObject.new(obj.id, obj.type, patch.value, obj.version + 1))
      end

      self
    end

    def reject_patch(patch_id : String, reason : String) : self
      patch = @store.get_patch(patch_id)
      raise GraphProjectionError.new("unknown patch: #{patch_id}") unless patch
      raise GraphProjectionError.new("patch #{patch_id} already #{patch.status}") unless patch.status.proposed?

      rejected = Patch.new(
        id: patch.id, target: patch.target, op: patch.op,
        value: patch.value, expected_version: patch.expected_version,
        proposed_by: patch.proposed_by,
        status: PatchState::Rejected,
        rejection_reason: reason,
      )
      @store.put_patch(rejected)
      self
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

    private def build_event(
      type : String,
      payload : String,
      actor : String,
      caused_by : String?,
    ) : Event
      Event.new(
        schema_version: 1_u16,
        sequence: next_sequence,
        id: @ids.event,
        type: type,
        actor: actor,
        caused_by: caused_by,
        timestamp: @clock.now,
        payload: payload,
      )
    end

    private def next_sequence : UInt64
      (@applied_events.size + 1).to_u64
    end

    private def object_created_payload(id : String, type : String, data : String) : String
      JSON.build do |json|
        json.object do
          json.field "id", id
          json.field "type", type
          json.field "data" do
            json.raw(data)
          end
          json.field "version", 1
        end
      end
    end

    private def relation_created_payload(
      id : String,
      type : String,
      source : String,
      target : String,
      data : String,
    ) : String
      JSON.build do |json|
        json.object do
          json.field "id", id
          json.field "type", type
          json.field "from_id", source
          json.field "to_id", target
          json.field "data" do
            json.raw(data)
          end
        end
      end
    end

    private def id_payload(id : String) : String
      JSON.build { |json| json.object { json.field "id", id } }
    end

    private def project_object!(payload : Hash(String, JSON::Any), provenance : Provenance) : Nil
      id = payload["id"].as_s
      object_type = payload["type"]?.try(&.as_s) || @store.get_object(id).try(&.type)
      data = payload["data"].to_json
      version = payload["version"]?.try(&.as_i.to_i64) || @store.get_object(id).try(&.version) || 1_i64
      raise GraphProjectionError.new("object type must be present") if object_type.nil?
      @store.put_object(GraphObject.new(id, object_type, data, version, provenance))
    end

    private def remove_object_from_state!(object_id : String) : Nil
      @store.remove_object(object_id)
      seen = Set(String).new
      (@store.find_relations(source: object_id) + @store.find_relations(target: object_id)).each do |relation|
        @store.remove_relation(relation.id) if seen.add?(relation.id)
      end
    end

    private def reject_reserved_fields!(data : String) : Nil
      JsonCompare.object_data_hash(data).each_key do |key|
        if RESERVED_DATA_FIELDS.includes?(key)
          raise ReservedFieldError.new("field '#{key}' is reserved and may not be set via data")
        end
      end
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
