require "json"

# Promote: apply a fork's net structural delta to its parent (CONTRACT v1.3
# #4; design `promote-design.md`). Ported from activegraph's
# activegraph/runtime/promote.py: a three-way comparison between the parent's
# state at the fork point (base), parent-now, and fork-now. Fork-only changes
# promote; both-sides changes conflict (fail-closed, atomic); parent-only
# changes are left alone. State is type + data (+ endpoints for relations);
# version counters and provenance are bookkeeping, not state.
module Chronicle
  # One entity that blocks a promote. `kind` is a stable discriminator:
  # "both_changed" (entity changed on both sides since the fork point,
  # including same-id both-created collisions and identical concurrent edits),
  # "dangling_relation" (a promoted relation's endpoint would not exist in
  # parent-post-promote state), or "orphaning_removal" (a promoted object
  # removal would cascade away a parent relation the delta doesn't remove).
  struct PromoteConflict
    getter kind : String
    getter entity : String
    getter id : String
    getter detail : String
    getter in_base : Hash(String, JSON::Any)?
    getter in_parent : Hash(String, JSON::Any)?
    getter in_fork : Hash(String, JSON::Any)?

    def initialize(
      @kind : String,
      @entity : String,
      @id : String,
      @detail : String,
      @in_base : Hash(String, JSON::Any)? = nil,
      @in_parent : Hash(String, JSON::Any)? = nil,
      @in_fork : Hash(String, JSON::Any)? = nil,
    )
    end
  end

  # What a promote would apply, computed against `computed_against` (the
  # parent tip event id at plan time). Returned by `promote(fork, dry_run: true)`.
  # Advisory only: apply always recomputes against parent-now. `is_promotable`
  # is the no-conflict check; `warnings` lists adjacent state promote
  # deliberately does not move (fork-only pack loads / settings overrides).
  class PromotePlan
    getter from_run : String
    getter into_run : String
    getter forked_at_event : String
    getter computed_against : String
    property object_creates : Array(Hash(String, JSON::Any))
    property object_patches : Array(Hash(String, JSON::Any))
    property object_removes : Array(String)
    property relation_creates : Array(Hash(String, JSON::Any))
    property relation_removes : Array(String)
    property conflicts : Array(PromoteConflict)
    property warnings : Array(String)

    def initialize(
      @from_run : String,
      @into_run : String,
      @forked_at_event : String,
      @computed_against : String,
      @object_creates : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      @object_patches : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      @object_removes : Array(String) = [] of String,
      @relation_creates : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      @relation_removes : Array(String) = [] of String,
      @conflicts : Array(PromoteConflict) = [] of PromoteConflict,
      @warnings : Array(String) = [] of String,
    )
    end

    # True when nothing conflicts — the plan can apply as-is.
    # ameba:disable Naming/PredicateName
    def is_promotable : Bool
      @conflicts.empty?
    end

    # True when the fork's delta is empty (nothing to promote).
    # ameba:disable Naming/PredicateName
    def is_empty : Bool
      @object_creates.empty? && @object_patches.empty? && @object_removes.empty? &&
        @relation_creates.empty? && @relation_removes.empty?
    end
  end

  # A completed promote: the applied plan plus its audit anchors.
  # `marker_event_id` is the `promote.applied` event; every applied delta event
  # is `caused_by` it and listed in `applied_event_ids` in emission order.
  class PromoteResult
    getter plan : PromotePlan
    getter marker_event_id : String
    getter applied_event_ids : Array(String)

    def initialize(
      @plan : PromotePlan,
      @marker_event_id : String,
      @applied_event_ids : Array(String) = [] of String,
    )
    end

    # The parent tip event id the applied plan was computed against.
    def computed_against : String
      @plan.computed_against
    end
  end

  module Promote
    extend self

    # Comparable object state: type + data. No version, no provenance.
    private def object_state(obj : GraphObject) : Hash(String, JSON::Any)
      {
        "type" => JSON::Any.new(obj.type),
        "data" => JSON.parse(obj.data),
      }
    end

    # Comparable relation state: endpoints + type.
    private def relation_state(rel : GraphRelation) : Hash(String, JSON::Any)
      {
        "source" => JSON::Any.new(rel.from_id),
        "target" => JSON::Any.new(rel.to_id),
        "type"   => JSON::Any.new(rel.type),
      }
    end

    # Reconstruct the parent's state at the fork point by replaying the
    # parent's log (projection-only) up to and including `forked_at_event`.
    # Raises `EventNotFoundError` when the id isn't in the parent's log —
    # callers translate to the structured lineage error.
    def build_base_graph(parent : GraphProjection, forked_at_event : String) : GraphProjection
      prefix = [] of Event
      found = false
      parent.events.each do |event|
        prefix << event
        if event.id == forked_at_event
          found = true
          break
        end
      end
      raise EventNotFoundError.new("fork point #{forked_at_event.inspect} not found in run") unless found
      GraphProjection.replay(prefix)
    end

    private def snapshot(graph : GraphProjection) : {Hash(String, Hash(String, JSON::Any)), Hash(String, Hash(String, JSON::Any))}
      objects = {} of String => Hash(String, JSON::Any)
      relations = {} of String => Hash(String, JSON::Any)
      graph.all_objects.each { |obj| objects[obj.id] = object_state(obj) }
      graph.all_relations.each { |rel| relations[rel.id] = relation_state(rel) }
      {objects, relations}
    end

    # Split ids into (creates, patches, removes) of the fork-only delta,
    # appending conflicts to the plan as found. Ported from the classify()
    # helper in activegraph's compute_promote_plan.
    private def classify(
      entity : String,
      ids : Array(String),
      base : Hash(String, Hash(String, JSON::Any)),
      parent_now : Hash(String, Hash(String, JSON::Any)),
      fork_now : Hash(String, Hash(String, JSON::Any)),
      conflicts : Array(PromoteConflict),
    ) : {Array(String), Array(String), Array(String)}
      creates = [] of String
      patches = [] of String
      removes = [] of String
      ids.sort!.each do |id|
        b = base[id]?
        p = parent_now[id]?
        f = fork_now[id]?
        fork_changed = f != b
        parent_changed = p != b
        next unless fork_changed # parent-only change or no change: not ours
        if parent_changed
          detail = if b.nil?
                     "#{id} was created independently on both sides after the fork point (id collision from the reseeded generators)"
                   elsif p.nil? && f.nil?
                     "#{id} was removed on both sides"
                   elsif p == f
                     "#{id} was changed identically on both sides — still a conflict in v1 (no semantic judgment)"
                   else
                     "#{id} changed on both sides since the fork point"
                   end
          conflicts << PromoteConflict.new(
            kind: "both_changed", entity: entity, id: id, detail: detail,
            in_base: b, in_parent: p, in_fork: f,
          )
          next
        end
        if f.nil?
          removes << id
        elsif b.nil?
          creates << id
        else
          patches << id
        end
      end
      {creates, patches, removes}
    end

    # Three-way structural comparison producing the fork's promotable delta
    # and every conflict. Pure: reads both graphs, mutates nothing.
    # Deterministic: sorted by entity id throughout.
    def compute_promote_plan(
      parent : GraphProjection,
      fork : GraphProjection,
      *,
      from_run : String,
      into_run : String,
      forked_at_event : String,
      warnings : Array(String) = [] of String,
    ) : PromotePlan
      base_graph = build_base_graph(parent, forked_at_event)
      base_obj, base_rel = snapshot(base_graph)
      parent_obj, parent_rel = snapshot(parent)
      fork_obj, fork_rel = snapshot(fork)

      plan = PromotePlan.new(
        from_run: from_run,
        into_run: into_run,
        forked_at_event: forked_at_event,
        computed_against: parent.events.empty? ? "" : parent.events[-1].id,
        warnings: warnings,
      )

      all_obj_ids = (base_obj.keys + parent_obj.keys + fork_obj.keys).uniq
      all_rel_ids = (base_rel.keys + parent_rel.keys + fork_rel.keys).uniq

      obj_creates, obj_patches, obj_removes = classify("object", all_obj_ids, base_obj, parent_obj, fork_obj, plan.conflicts)
      rel_creates, rel_patches, rel_removes = classify("relation", all_rel_ids, base_rel, parent_rel, fork_rel, plan.conflicts)

      # A relation whose endpoints/type changed is remove+create in apply terms
      # (the projection has no relation-patch event). Fold patches into both.
      rel_removes = (rel_removes + rel_patches).uniq.sort!
      rel_creates = (rel_creates + rel_patches).uniq.sort!

      check_referential_integrity(
        plan,
        obj_creates, obj_removes, rel_creates, rel_removes,
        base_obj, parent_obj, parent_rel, fork_rel,
      )

      # ---- materialize the delta payloads (sorted, deterministic) ----
      plan.object_creates = obj_creates.map { |object_id| {"id" => JSON::Any.new(object_id)}.merge(fork_obj[object_id]) }
      plan.object_patches = obj_patches.map { |object_id| {"id" => JSON::Any.new(object_id)}.merge(fork_obj[object_id]) }
      plan.object_removes = obj_removes
      plan.relation_creates = rel_creates.map { |relation_id| {"id" => JSON::Any.new(relation_id)}.merge(fork_rel[relation_id]) }
      plan.relation_removes = rel_removes
      plan.conflicts.sort_by! { |conflict| {conflict.kind, conflict.entity, conflict.id} }
      plan
    end

    # Referential integrity (design §4, review amendment #2): a promoted
    # relation whose endpoint won't exist post-promote conflicts, and so does a
    # promoted object removal that would cascade away a parent relation the
    # delta doesn't remove. Appends conflicts to the plan in place.
    private def check_referential_integrity(
      plan : PromotePlan,
      obj_creates : Array(String),
      obj_removes : Array(String),
      rel_creates : Array(String),
      rel_removes : Array(String),
      base_obj : Hash(String, Hash(String, JSON::Any)),
      parent_obj : Hash(String, Hash(String, JSON::Any)),
      parent_rel : Hash(String, Hash(String, JSON::Any)),
      fork_rel : Hash(String, Hash(String, JSON::Any)),
    ) : Nil
      removed_objects = obj_removes.to_set
      created_objects = obj_creates.to_set
      delta_removed_relations = rel_removes.to_set

      endpoint_survives = ->(object_id : String) {
        if created_objects.includes?(object_id)
          true
        else
          parent_obj.has_key?(object_id) && !removed_objects.includes?(object_id)
        end
      }

      rel_creates.each do |relation_id|
        state = fork_rel[relation_id]
        missing = [] of String
        [state["source"].as_s, state["target"].as_s].each do |endpoint|
          missing << endpoint unless endpoint_survives.call(endpoint)
        end
        unless missing.empty?
          plan.conflicts << PromoteConflict.new(
            kind: "dangling_relation", entity: "relation", id: relation_id,
            detail: "#{relation_id} (#{state["source"]} --#{state["type"]}--> #{state["target"]}) references #{missing.sort.join(", ")}, which would not exist in the parent after this promote",
            in_fork: state,
          )
        end
      end

      obj_removes.each do |object_id|
        orphaned = parent_rel.keys.select do |relation_id|
          state = parent_rel[relation_id]
          object_id.in?({state["source"].as_s, state["target"].as_s}) && !delta_removed_relations.includes?(relation_id)
        end.sort!
        unless orphaned.empty?
          plan.conflicts << PromoteConflict.new(
            kind: "orphaning_removal", entity: "object", id: object_id,
            detail: "removing #{object_id} would cascade away parent relation(s) #{orphaned.join(", ")} that the fork never touched",
            in_base: base_obj[object_id]?,
            in_parent: parent_obj[object_id]?,
          )
        end
      end
    end

    # Adjacent state promote surfaces but never applies (design §5): packs
    # loaded in the fork but not the parent, and fork-tail
    # `pack.settings_overridden` events. Fork-only-ness is positional — every
    # event after `forked_at_event` in the fork's log is the fork's own — never
    # an event-id membership check (ids are run-scoped).
    def promote_warnings(
      parent_events : Array(Event),
      fork_events : Array(Event),
      forked_at_event : String,
    ) : Array(String)
      warnings = [] of String
      parent_packs = loaded_pack_keys(parent_events)
      in_tail = false
      fork_events.each do |event|
        if !in_tail
          if event.id == forked_at_event
            in_tail = true
          end
          next
        end
        warning = fork_tail_warning(event, parent_packs)
        warnings << warning if warning
      end
      warnings
    end

    # Set of {name, version} pack keys loaded anywhere in `events`.
    private def loaded_pack_keys(events : Array(Event)) : Set({String, String})
      keys = Set({String, String}).new
      events.each do |event|
        next unless event.type == "pack.loaded"
        payload = JSON.parse(event.payload).as_h
        keys << {payload["name"]?.try(&.as_s) || "", payload["version"]?.try(&.as_s) || ""}
      end
      keys
    end

    # One warning for a fork-tail event, or nil. Pack loads the parent lacks and
    # `pack.settings_overridden` events surface as governance signals.
    private def fork_tail_warning(event : Event, parent_packs : Set({String, String})) : String?
      payload = JSON.parse(event.payload).as_h
      case event.type
      when "pack.loaded"
        key = {payload["name"]?.try(&.as_s) || "", payload["version"]?.try(&.as_s) || ""}
        return nil if parent_packs.includes?(key)
        "fork has pack #{key[0]}@#{key[1]} loaded that the parent does not; promote never adopts code — call parent.load_pack(...) explicitly if the promoted state depends on it"
      when "pack.settings_overridden"
        assignments = payload["assignments"]?.try(&.as_a) || [] of JSON::Any
        rendered = if assignments.empty?
                     payload["overrides"]?.try(&.to_json) || "?"
                   else
                     assignments.map(&.as_s).join(", ")
                   end
        "fork carries a settings override for pack #{payload["pack"]?.try(&.as_s) || "?"} (#{rendered}) that promote does not transfer; re-apply it on the parent explicitly if the promoted state depends on it"
      else
        nil
      end
    end
  end
end
