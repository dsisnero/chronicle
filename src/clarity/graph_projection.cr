require "json"

module Clarity
  struct GraphObject
    getter id : String
    getter type : String
    getter data : String

    def initialize(@id : String, @type : String, @data : String)
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

    def initialize(
      @added_object_ids : Array(String),
      @removed_object_ids : Array(String),
      @added_relation_ids : Array(String),
      @removed_relation_ids : Array(String),
    )
    end
  end

  # Pure graph state reconstructed from typed object and relation events.
  class GraphProjection
    @objects : Hash(String, GraphObject)
    @relations : Hash(String, GraphRelation)

    def initialize(
      @objects = {} of String => GraphObject,
      @relations = {} of String => GraphRelation,
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

    def apply(event : Event) : self
      objects = @objects.dup
      relations = @relations.dup
      payload = JSON.parse(event.payload).as_h

      case event.type
      when "object.created", "object.patched"
        id = payload["id"].as_s
        object_type = payload["type"]?.try(&.as_s) || objects[id]?.try(&.type)
        data = payload["data"].to_json
        unless object_type
          raise GraphProjectionError.new("object type must be present")
        end
        objects[id] = GraphObject.new(id, object_type, data)
      when "relation.created"
        id = payload["id"].as_s
        relations[id] = GraphRelation.new(
          id,
          payload["type"].as_s,
          payload["from_id"].as_s,
          payload["to_id"].as_s
        )
      end

      self.class.new(objects, relations)
    rescue KeyError | JSON::ParseException
      raise GraphProjectionError.new("invalid graph event payload")
    end

    def diff(other : GraphProjection) : GraphDiff
      GraphDiff.new(
        other.objects.keys.reject { |id| @objects.has_key?(id) }.sort!,
        @objects.keys.reject { |id| other.objects.has_key?(id) }.sort!,
        other.relations.keys.reject { |id| @relations.has_key?(id) }.sort!,
        @relations.keys.reject { |id| other.relations.has_key?(id) }.sort!
      )
    end
  end
end
