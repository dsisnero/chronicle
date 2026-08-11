require "json"

module Chronicle
  enum ReplayMode
    Permissive
    Strict
  end

  struct ReplayResult
    getter projection : GraphProjection
    getter effects : Hash(String, EffectResult)

    def initialize(@projection : GraphProjection, @effects : Hash(String, EffectResult))
    end
  end

  # Reconstructs pure state and recorded effect results without live execution.
  class ReplayEngine
    def replay(
      recorded_events : Array(Event),
      mode : ReplayMode,
      emitted_events : Array(Event) = [] of Event,
      store : EffectArtifactStore? = nil,
      llm_cache : LLMCache? = nil,
    ) : ReplayResult
      assert_strict_replay(recorded_events, emitted_events) if mode.strict?

      effects = if c = llm_cache
                  c.entries
                elsif s = store
                  s.results
                else
                  extract_effects(recorded_events)
                end
      ReplayResult.new(GraphProjection.replay(recorded_events), effects)
    end

    private def extract_effects(events : Array(Event)) : Hash(String, EffectResult)
      effects = {} of String => EffectResult
      events.each do |event|
        next unless event.type == "effect.responded"

        payload = JSON.parse(event.payload).as_h
        hash = payload["hash"].as_s
        effects[hash] = EffectResult.new(hash, payload["success"].as_bool, payload["payload"].to_json)
      end
      effects
    rescue KeyError | JSON::ParseException
      raise ReplayDivergenceError.new("invalid recorded effect result")
    end

    private def assert_strict_replay(recorded_events : Array(Event), emitted_events : Array(Event)) : Nil
      recorded = recorded_events.reject { |e| Chronicle::RuntimeReason.lifecycle?(e) }
      emitted = emitted_events.reject { |e| Chronicle::RuntimeReason.lifecycle?(e) }
      max_size = {recorded.size, emitted.size}.max
      max_size.times do |index|
        recorded_event = recorded[index]?
        emitted_event = emitted[index]?
        if recorded_event.nil? || emitted_event.nil? || recorded_event.canonical_json != emitted_event.canonical_json
          sequence = recorded_event.try(&.sequence) || emitted_event.try(&.sequence) || 0_u64
          raise ReplayDivergenceError.new("replay diverged at sequence #{sequence}")
        end
      end
    end
  end
end
