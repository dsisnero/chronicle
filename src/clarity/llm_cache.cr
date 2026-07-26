module Clarity
  # Content-addressed cache for LLM responses keyed by prompt hash.
  #
  # Ported from activegraph.llm.cache.LLMCache (CONTRACT v0.6 #8).
  # The cache is keyed by content hash (SHA-256 of canonical request
  # JSON), not by event id — that's what lets a fork's regenerated
  # prompts hit the same recorded responses.
  class LLMCache
    def initialize
      @entries = {} of String => EffectResult
    end

    # All cached entries as a hash (used by ReplayEngine).
    def entries : Hash(String, EffectResult)
      @entries.dup
    end

    # Number of cached entries.
    def size : Int32
      @entries.size
    end

    # Retrieve a cached response by prompt hash. Returns nil on miss.
    def get(hash : String) : EffectResult?
      @entries[hash]?
    end

    # Record a response for a prompt hash. Overwrites on collision.
    def record(hash : String, result : EffectResult) : Nil
      @entries[hash] = result
    end

    # Bulk-populate from a sequence of effect.requested + effect.responded
    # events. Walks the log pairing effect.responded.caused_by back to
    # effect.requested.id to find the content hash.
    def self.from_events(events : Array(Event)) : self
      cache = new
      by_id = {} of String => Event
      events.each { |e| by_id[e.id] = e }

      events.each do |evt|
        next unless evt.type == "effect.responded"

        payload = JSON.parse(evt.payload).as_h
        next unless payload["success"]?.try(&.as_bool) == true

        hash = payload["hash"]?.try(&.as_s)
        next unless hash

        # Reconstruct result from the event payload
        result_payload = payload["payload"].to_json
        result = EffectResult.new(hash, true, result_payload)
        cache.record(hash, result)
      end
      cache
    rescue JSON::ParseException
      cache || LLMCache.new
    end
  end
end
