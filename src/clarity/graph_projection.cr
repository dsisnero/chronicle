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

  struct Patch
    getter id : String
    getter target : String
    getter op : PatchOp
    getter value : String
    getter expected_version : Int64
    getter proposed_by : String
    getter status : PatchState
    getter rejection_reason : String?

    def initialize(
      @id : String,
      @target : String,
      @op : PatchOp,
      @value : String,
      @expected_version : Int64,
      @proposed_by : String,
      @status : PatchState = PatchState::Proposed,
      @rejection_reason : String? = nil,
    )
    end
  end

  struct GraphObject
    getter id : String
    getter type : String
    getter data : String
    getter version : Int64

    def initialize(@id : String, @type : String, @data : String, @version : Int64 = 1)
    end
  end

  struct GraphRelation
    getter id : String
    getter type : String
    getter from_id : String
    getter to_id : String

    def initialize(@id : String, @type : String, @from_id : String, @to_id : String)
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
  class GraphProjection
    @objects : Hash(String, GraphObject)
    @relations : Hash(String, GraphRelation)
    @patches : Hash(String, Patch)
    @patch_ids_by_target : Hash(String, Array(String))
    @applied_events : Array(Event)

    def initialize(
      @objects = {} of String => GraphObject,
      @relations = {} of String => GraphRelation,
      @patches = {} of String => Patch,
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

    def objects : Hash(String, GraphObject)
      @objects.dup
    end

    def relations : Hash(String, GraphRelation)
      @relations.dup
    end

    def patches : Hash(String, Patch)
      @patches.dup
    end

    def get_object(id : String) : GraphObject?
      @objects[id]?
    end

    def get_patch(id : String) : Patch?
      @patches[id]?
    end

    def apply(event : Event) : self
      objects = @objects.dup
      relations = @relations.dup
      patches = @patches.dup
      patch_ids_by_target = @patch_ids_by_target.dup
      applied_events = @applied_events.dup
      applied_events << event
      payload = JSON.parse(event.payload).as_h

      case event.type
      when "object.created", "object.patched"
        id = payload["id"].as_s
        object_type = payload["type"]?.try(&.as_s) || objects[id]?.try(&.type)
        data = payload["data"].to_json
        version = payload["version"]?.try(&.as_i.to_i64) || objects[id]?.try(&.version) || 1_i64
        unless object_type
          raise GraphProjectionError.new("object type must be present")
        end
        objects[id] = GraphObject.new(id, object_type, data, version)
      when "relation.created"
        id = payload["id"].as_s
        relations[id] = GraphRelation.new(
          id,
          payload["type"].as_s,
          payload["from_id"].as_s,
          payload["to_id"].as_s
        )
      when "patch.proposed"
        patch_data = payload["patch"].as_h
        patch = parse_patch(patch_data, PatchState::Proposed)
        patches[patch.id] = patch
        ids = patch_ids_by_target.fetch(patch.target, [] of String)
        patch_ids_by_target[patch.target] = ids + [patch.id]
      when "patch.applied"
        patch_data = payload["patch"].as_h
        target_id = payload["target"].as_s
        patch = parse_patch(patch_data, PatchState::Applied)
        patches[patch.id] = patch
        if obj = objects[target_id]?
          objects[target_id] = GraphObject.new(obj.id, obj.type, patch.value, obj.version + 1)
        end
      when "patch.rejected"
        patch_data = payload["patch"].as_h
        patch = parse_patch(patch_data, PatchState::Rejected)
        patches[patch.id] = patch
      end

      self.class.new(objects, relations, patches, patch_ids_by_target, applied_events)
    rescue KeyError | JSON::ParseException
      raise GraphProjectionError.new("invalid graph event payload")
    end

    def build_view(spec : ViewSpec = ViewSpec.new) : View
      objs = @objects.values
      rels = @relations.values

      if types = spec.include_types
        type_set = types.to_set
        objs = objs.select { |obj| type_set.includes?(obj.type) }
      end

      if around = spec.around
        center = @objects[around]?
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
      obj = @objects[target]?
      ver = expected_version || obj.try(&.version) || 0_i64
      patch = Patch.new(
        id: patch_id || "patch_#{@patches.size + 1}",
        target: target,
        op: PatchOp.parse(op),
        value: value,
        expected_version: ver,
        proposed_by: proposed_by,
        status: PatchState::Proposed,
      )
      @patches[patch.id] = patch
      ids = @patch_ids_by_target.fetch(target, [] of String)
      @patch_ids_by_target[target] = ids + [patch.id]
      patch
    end

    def apply_patch(patch_id : String) : self
      patch = @patches[patch_id]?
      raise GraphProjectionError.new("unknown patch: #{patch_id}") unless patch
      raise GraphProjectionError.new("patch #{patch_id} already #{patch.status}") unless patch.status.proposed?

      objects = @objects.dup
      patches = @patches.dup

      obj = objects[patch.target]?
      current_version = obj.try(&.version) || 0_i64

      if current_version != patch.expected_version
        rejected = Patch.new(
          id: patch.id, target: patch.target, op: patch.op,
          value: patch.value, expected_version: patch.expected_version,
          proposed_by: patch.proposed_by,
          status: PatchState::Rejected,
          rejection_reason: "version mismatch: expected #{patch.expected_version}, got #{current_version}",
        )
        patches[patch.id] = rejected
        return self.class.new(objects, @relations.dup, patches, @patch_ids_by_target.dup)
      end

      applied = Patch.new(
        id: patch.id, target: patch.target, op: patch.op,
        value: patch.value, expected_version: patch.expected_version,
        proposed_by: patch.proposed_by,
        status: PatchState::Applied,
      )
      patches[patch.id] = applied

      if obj
        objects[patch.target] = GraphObject.new(obj.id, obj.type, patch.value, obj.version + 1)
      end

      self.class.new(objects, @relations.dup, patches, @patch_ids_by_target.dup)
    end

    def reject_patch(patch_id : String, reason : String) : self
      patch = @patches[patch_id]?
      raise GraphProjectionError.new("unknown patch: #{patch_id}") unless patch
      raise GraphProjectionError.new("patch #{patch_id} already #{patch.status}") unless patch.status.proposed?

      patches = @patches.dup
      rejected = Patch.new(
        id: patch.id, target: patch.target, op: patch.op,
        value: patch.value, expected_version: patch.expected_version,
        proposed_by: patch.proposed_by,
        status: PatchState::Rejected,
        rejection_reason: reason,
      )
      patches[patch.id] = rejected
      self.class.new(@objects.dup, @relations.dup, patches, @patch_ids_by_target.dup)
    end

    def diff(other : GraphProjection) : GraphDiff
      GraphDiff.new(
        other.objects.keys.reject { |id| @objects.has_key?(id) }.sort!,
        @objects.keys.reject { |id| other.objects.has_key?(id) }.sort!,
        other.relations.keys.reject { |id| @relations.has_key?(id) }.sort!,
        @relations.keys.reject { |id| other.relations.has_key?(id) }.sort!,
        other.patches.keys.reject { |id| @patches.has_key?(id) }.sort!,
        @patches.keys.reject { |id| other.patches.has_key?(id) }.sort!,
      )
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
