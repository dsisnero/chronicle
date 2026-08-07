require "json"

# Structural diff between two runs (typically parent vs fork). Ported from
# activegraph.runtime.diff (CONTRACT v0.5 #10): diff is structural only —
# divergent objects, divergent relations, and which event ranges belong to
# each side. Semantic comparison is a behavior's job, not the runtime's.
#
# Events are partitioned by walking both logs: lifecycle events
# (`behavior.*`, `relation_behavior.*`, `runtime.*`) are scaffolding, not
# history, and are filtered out; the remaining events share a prefix that
# matches by id, type AND payload (a same-id different-payload collision is
# NOT shared — logical ids are scoped to a run, CONTRACT #12). Divergent
# objects/relations are per-id provenance-stripped snapshots.
module Chronicle
  # One object id whose final state differs between parent and fork.
  # `in_parent` / `in_fork` are provenance-stripped snapshots so the
  # comparison is structural; nil on the side where the id doesn't exist.
  struct DivergentObject
    getter id : String
    getter in_parent : Hash(String, JSON::Any)?
    getter in_fork : Hash(String, JSON::Any)?

    def initialize(@id : String, @in_parent : Hash(String, JSON::Any)?, @in_fork : Hash(String, JSON::Any)?)
    end

    def summary : String
      if in_parent.nil?
        "#{id} only in fork"
      elsif in_fork.nil?
        "#{id} only in parent"
      else
        parent_version = in_parent.try(&.["version"]?.try(&.as_i64))
        fork_version = in_fork.try(&.["version"]?.try(&.as_i64))
        "#{id} differs (parent v#{parent_version} ↔ fork v#{fork_version})"
      end
    end
  end

  # One relation id whose final state differs between parent and fork. Same
  # shape as `DivergentObject`.
  struct DivergentRelation
    getter id : String
    getter in_parent : Hash(String, JSON::Any)?
    getter in_fork : Hash(String, JSON::Any)?

    def initialize(@id : String, @in_parent : Hash(String, JSON::Any)?, @in_fork : Hash(String, JSON::Any)?)
    end

    def summary : String
      if in_parent.nil? && (state = in_fork)
        "#{id} only in fork (#{state["source"]} --#{state["type"]}--> #{state["target"]})"
      elsif in_fork.nil? && (state = in_parent)
        "#{id} only in parent (#{state["source"]} --#{state["type"]}--> #{state["target"]})"
      else
        "#{id} differs"
      end
    end
  end

  # Structural comparison of two runs. `is_identical?` is the no-divergence
  # check. Immutable struct; `copy_with` derives modified copies.
  struct Diff
    getter parent_run_id : String
    getter fork_run_id : String
    getter shared_events : Array(Event)
    getter parent_only_events : Array(Event)
    getter fork_only_events : Array(Event)
    getter divergent_objects : Array(DivergentObject)
    getter divergent_relations : Array(DivergentRelation)
    getter? identical : Bool = false

    def initialize(
      @parent_run_id : String,
      @fork_run_id : String,
      @shared_events : Array(Event) = [] of Event,
      @parent_only_events : Array(Event) = [] of Event,
      @fork_only_events : Array(Event) = [] of Event,
      @divergent_objects : Array(DivergentObject) = [] of DivergentObject,
      @divergent_relations : Array(DivergentRelation) = [] of DivergentRelation,
    )
      # True when the runs have no parent-only / fork-only events and no
      # divergent objects or relations (upstream `is_identical` property).
      @identical = @parent_only_events.empty? && @fork_only_events.empty? &&
                   @divergent_objects.empty? && @divergent_relations.empty?
    end

    def copy_with(
      @parent_run_id : String = @parent_run_id,
      @fork_run_id : String = @fork_run_id,
      @shared_events : Array(Event) = @shared_events,
      @parent_only_events : Array(Event) = @parent_only_events,
      @fork_only_events : Array(Event) = @fork_only_events,
      @divergent_objects : Array(DivergentObject) = @divergent_objects,
      @divergent_relations : Array(DivergentRelation) = @divergent_relations,
    ) : Diff
      Diff.new(
        parent_run_id: @parent_run_id, fork_run_id: @fork_run_id,
        shared_events: @shared_events, parent_only_events: @parent_only_events,
        fork_only_events: @fork_only_events, divergent_objects: @divergent_objects,
        divergent_relations: @divergent_relations,
      )
    end

    # Structural comparison of `parent` vs `fork`. Pure: reads both graphs and
    # their recorded event logs, mutates nothing. Ported from
    # activegraph.runtime.diff.compute_diff. `parent_events` / `fork_events`
    # are the runs' append-only logs (the authoritative history).
    def self.compute(
      parent : GraphProjection,
      fork : GraphProjection,
      *,
      parent_events : Array(Event),
      fork_events : Array(Event),
      parent_run_id : String,
      fork_run_id : String,
    ) : Diff
      parent_events = parent_events.select { |event| !lifecycle?(event) }
      fork_events = fork_events.select { |event| !lifecycle?(event) }

      # Shared prefix: events that match by id, type AND payload. Same id with
      # different content means the fork already diverged (logical ids are
      # scoped to run_id — CONTRACT #12 — so collisions after the fork point
      # are expected and must not be flattened into "shared".)
      shared = [] of Event
      index = 0
      while index < parent_events.size && index < fork_events.size
        a = parent_events[index]
        b = fork_events[index]
        if a.id == b.id && a.type == b.type && JSON.parse(a.payload) == JSON.parse(b.payload)
          shared << a
          index += 1
        else
          break
        end
      end
      parent_only = parent_events[index..]
      fork_only = fork_events[index..]

      # Object divergence.
      divergent_objects = [] of DivergentObject
      parent_objs = parent.all_objects.to_h { |obj| {obj.id, obj} }
      fork_objs = fork.all_objects.to_h { |obj| {obj.id, obj} }
      (parent_objs.keys | fork_objs.keys).sort!.each do |oid|
        parent_state = parent_objs[oid]?.try { |obj| object_state(obj) }
        fork_state = fork_objs[oid]?.try { |obj| object_state(obj) }
        if parent_state != fork_state
          divergent_objects << DivergentObject.new(oid, parent_state, fork_state)
        end
      end

      # Relation divergence.
      divergent_relations = [] of DivergentRelation
      parent_rels = parent.all_relations.to_h { |rel| {rel.id, rel} }
      fork_rels = fork.all_relations.to_h { |rel| {rel.id, rel} }
      (parent_rels.keys | fork_rels.keys).sort!.each do |rid|
        parent_state = parent_rels[rid]?.try { |rel| relation_state(rel) }
        fork_state = fork_rels[rid]?.try { |rel| relation_state(rel) }
        if parent_state != fork_state
          divergent_relations << DivergentRelation.new(rid, parent_state, fork_state)
        end
      end

      Diff.new(
        parent_run_id: parent_run_id, fork_run_id: fork_run_id,
        shared_events: shared, parent_only_events: parent_only,
        fork_only_events: fork_only, divergent_objects: divergent_objects,
        divergent_relations: divergent_relations,
      )
    end

    # Lifecycle events are scaffolding, not history: `behavior.*`,
    # `relation_behavior.*`, `runtime.*`. `promote.*` is NOT lifecycle.
    private def self.lifecycle?(event : Event) : Bool
      event.type.starts_with?("behavior.") || event.type.starts_with?("relation_behavior.") ||
        event.type.starts_with?("runtime.")
    end

    # Provenance-stripped comparable object snapshot: type + data + version.
    private def self.object_state(obj : GraphObject) : Hash(String, JSON::Any)
      {
        "id"      => JSON::Any.new(obj.id),
        "type"    => JSON::Any.new(obj.type),
        "data"    => JSON.parse(obj.data),
        "version" => JSON::Any.new(obj.version),
      }
    end

    # Provenance-stripped comparable relation snapshot: endpoints + type.
    private def self.relation_state(rel : GraphRelation) : Hash(String, JSON::Any)
      {
        "id"     => JSON::Any.new(rel.id),
        "type"   => JSON::Any.new(rel.type),
        "source" => JSON::Any.new(rel.from_id),
        "target" => JSON::Any.new(rel.to_id),
      }
    end
  end
end
