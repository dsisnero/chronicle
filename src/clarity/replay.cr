require "json"

module Clarity
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
    ) : ReplayResult
      assert_strict_replay(recorded_events, emitted_events) if mode.strict?

      effects = {} of String => EffectResult
      recorded_events.each do |event|
        next unless event.type == "effect.responded"

        payload = JSON.parse(event.payload).as_h
        hash = payload["hash"].as_s
        effects[hash] = EffectResult.new(hash, payload["success"].as_bool, payload["payload"].to_json)
      end
      ReplayResult.new(GraphProjection.replay(recorded_events), effects)
    rescue KeyError | JSON::ParseException
      raise ReplayDivergenceError.new("invalid recorded effect result")
    end

    private def assert_strict_replay(recorded_events : Array(Event), emitted_events : Array(Event)) : Nil
      max_size = {recorded_events.size, emitted_events.size}.max
      max_size.times do |index|
        recorded = recorded_events[index]?
        emitted = emitted_events[index]?
        if recorded.nil? || emitted.nil? || recorded.canonical_json != emitted.canonical_json
          sequence = recorded.try(&.sequence) || emitted.try(&.sequence) || 0_u64
          raise ReplayDivergenceError.new("replay diverged at sequence #{sequence}")
        end
      end
    end
  end
end
