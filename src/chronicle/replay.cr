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
      # Ports activegraph.runtime.runtime._verify_replay's stream comparison
      # (runtime.py #L4342-L4368): both sides drop lifecycle events and promote
      # blocks; the recorded side additionally drops non-replayable failed LLM
      # attempt pairs and operator-invoked (direct) embedding pairs that no
      # behavior re-derives. The first type mismatch is pinned at the recorded
      # event id with expected/actual; a length mismatch pins the first
      # unpaired position.
      non_replayable = Chronicle::RuntimeReason.non_replayable_llm_attempt_event_ids(recorded_events)
      direct_embedding = Chronicle::RuntimeReason.direct_embedding_event_ids(recorded_events)

      rec_stream = recorded_events.compact_map do |event|
        next if Chronicle::RuntimeReason.lifecycle?(event)
        next if non_replayable.includes?(event.id)
        next if direct_embedding.includes?(event.id)
        next if Chronicle::RuntimeReason.promote_block?(event)
        {event.id, event.type}
      end
      new_stream = emitted_events.compact_map do |event|
        next if Chronicle::RuntimeReason.lifecycle?(event)
        next if Chronicle::RuntimeReason.promote_block?(event)
        {event.id, event.type}
      end

      {rec_stream.size, new_stream.size}.min.times do |index|
        rec_id, rec_type = rec_stream[index]
        new_type = new_stream[index][1]
        if new_type != rec_type
          raise ReplayDivergenceError.new(event_id: rec_id, expected: rec_type, actual: new_type)
        end
      end

      if rec_stream.size != new_stream.size
        if new_stream.size < rec_stream.size
          # Live re-run finished early: the recorded stream has an event the
          # replay never produced.
          rec_id, rec_type = rec_stream[new_stream.size]
          raise ReplayDivergenceError.new(event_id: rec_id, expected: rec_type, actual: nil)
        else
          # Live re-run produced an event the recorded log does not contain.
          new_id, new_type = new_stream[rec_stream.size]
          raise ReplayDivergenceError.new(
            event_id: new_id,
            expected: ReplayDivergenceError::NO_RECORDED_EVENT,
            actual: new_type,
          )
        end
      end
    end
  end
end
