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

    def has(hash : String) : Bool
      @entries.has_key?(hash)
    end

    # Record a response for a prompt hash. Overwrites on collision.
    def record(hash : String, result : EffectResult) : Nil
      @entries[hash] = result
    end

    # Bulk-populate from a sequence of recorded events. Walks the log pairing
    # llm.responded.caused_by back to llm.requested for the request hash
    # (error-shaped llm.responded events are failed attempts and are skipped),
    # and effect.responded events for the effect-request path.
    def self.from_events(events : Array(Event)) : self
      cache = new
      by_id = {} of String => Event
      events.each { |e| by_id[e.id] = e }

      events.each do |evt|
        case evt.type
        when "effect.responded"
          harvest_effect_responded(cache, evt)
        when "llm.responded"
          harvest_llm_responded(cache, evt, by_id)
        end
      end
      cache
    rescue JSON::ParseException
      cache || LLMCache.new
    end

    private def self.harvest_effect_responded(cache : self, evt : Event) : Nil
      payload = JSON.parse(evt.payload).as_h
      return unless payload["success"]?.try(&.as_bool) == true

      hash = payload["hash"]?.try(&.as_s)
      return unless hash

      result_payload = payload["payload"]?.try(&.to_json)
      return if result_payload.nil?

      cache.record(hash, EffectResult.new(hash, true, result_payload))
    end

    private def self.harvest_llm_responded(cache : self, evt : Event, by_id : Hash(String, Event)) : Nil
      payload = JSON.parse(evt.payload).as_h
      return if payload["error"]?

      request_id = evt.caused_by
      return if request_id.nil?

      request = by_id[request_id]?
      return if request.nil? || request.type != "llm.requested"

      request_payload = JSON.parse(request.payload).as_h
      hash = request_payload["request_hash"]?.try(&.as_s)
      return if hash.nil? || hash.empty?

      cache.record(hash, EffectResult.new(hash, true, payload.to_json))
    end
  end
end
