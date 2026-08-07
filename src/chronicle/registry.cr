require "json"

# Match events to behaviors (CONTRACT #10: registration order for ties).
# Ported from activegraph.runtime.registry: `match(event, graph)` returns
# (behavior, matching_relations, pattern_matches) triples in registration
# order. A behavior with both `on=[...]` and `pattern=...` requires BOTH
# conditions — the event type matches AND the pattern matches against the
# post-event graph state. A behavior with only `pattern=` (empty `on`) matches
# on every non-lifecycle event. `matches` is the pattern matcher's bindings
# (empty for behaviors without `pattern=`).
module Chronicle
  # One behavior/relations/matches match of an event against a graph.
  struct RegistryMatch
    getter behavior : Packs::PackBehavior
    getter relations : Array(GraphRelation)
    getter pattern_matches : Array(Match)

    def initialize(
      @behavior : Packs::PackBehavior,
      @relations : Array(GraphRelation),
      @pattern_matches : Array(Match),
    )
    end
  end

  # Registration-ordered behavior matching over an event log + graph state.
  class Registry
    getter behaviors : Array(Packs::PackBehavior)

    def initialize(@behaviors : Array(Packs::PackBehavior))
    end

    def all : Array(Packs::PackBehavior)
      @behaviors.dup
    end

    def index_of(behavior : Packs::PackBehavior) : Int32
      @behaviors.index(behavior) || -1
    end

    # Return (behavior, matching_relations, pattern_matches) triples in
    # registration order. Pattern matches are empty for behaviors without
    # `pattern=`. Ported from activegraph.runtime.registry.Registry#match.
    def match(event : Event, graph : GraphProjection) : Array(RegistryMatch)
      out = [] of RegistryMatch
      @behaviors.each do |behavior|
        # Event-type filter: required only when `on=` is non-empty.
        # Pattern-only behaviors (empty `on`) skip this gate.
        unless behavior.event_types.empty?
          next unless behavior.event_types.includes?(event.type)
        end
        # Suppress lifecycle events for pattern-only behaviors so a pattern
        # doesn't fire on behavior.started, etc.
        if behavior.event_types.empty? && behavior.pattern && lifecycle?(event)
          next
        end

        pattern_matches = [] of Match
        if pattern = behavior.pattern
          matcher = Chronicle.parse(pattern).compile
          pattern_matches = matcher.matches(event, graph)
          next if pattern_matches.empty?
        end

        if behavior.kind == Packs::PackBehaviorKind::Relation
          relations = matching_relations(behavior, event, graph)
          unless relations.empty?
            out << RegistryMatch.new(behavior, relations, pattern_matches)
          end
        else
          if where = behavior.where
            next unless Packs.where_matches?(where, event.payload)
          end
          out << RegistryMatch.new(behavior, [] of GraphRelation, pattern_matches)
        end
      end
      out
    end

    # Relation-type filter pushed down to the graph's relations; the
    # reference/where checks stay here. A candidate relation matches when the
    # event payload references its source or target id. Ported from
    # activegraph.runtime.registry._matching_relations.
    private def matching_relations(
      behavior : Packs::PackBehavior,
      event : Event,
      graph : GraphProjection,
    ) : Array(GraphRelation)
      relation_type = behavior.relation_type
      return [] of GraphRelation if relation_type.nil?

      referenced = collect_string_values(JSON.parse(event.payload))
      candidates = graph.relations(type: relation_type)
      out = [] of GraphRelation
      candidates.each do |relation|
        next unless referenced.includes?(relation.from_id) || referenced.includes?(relation.to_id)
        if where = behavior.where
          next unless Packs.where_matches?(where, event.payload)
        end
        out << relation
      end
      out
    end

    # Every string value reachable in a JSON structure (recursively), used to
    # find which candidate relations an event references. Ported from
    # activegraph.runtime.registry._collect_string_values/_walk.
    private def collect_string_values(json : JSON::Any) : Set(String)
      values = Set(String).new
      walk(json, values)
      values
    end

    private def walk(json : JSON::Any, values : Set(String)) : Nil
      case json.raw
      when String
        values << json.as_s
      when Hash
        json.as_h.each_value { |value| walk(value, values) }
      when Array
        json.as_a.each { |value| walk(value, values) }
      end
    end

    private def lifecycle?(event : Event) : Bool
      event.type.starts_with?("behavior.") ||
        event.type.starts_with?("relation_behavior.") ||
        event.type.starts_with?("runtime.") ||
        event.type.starts_with?("llm.") ||
        event.type.starts_with?("tool.") ||
        event.type.starts_with?("embedding.") ||
        event.type.starts_with?("dev.")
    end
  end
end
