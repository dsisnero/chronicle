require "json"
require "digest/sha256"

module Chronicle
  # Content-keyed replay cache for runtime-owned embedding calls (CONTRACT
  # v1.8 #6, upstream llm/embedding_cache.py). Requests are keyed by canonical
  # input content (model + ordered texts); successful recorded returns hydrate
  # a fresh runtime; cache reads return defensive copies so callers cannot
  # mutate the replay authority.
  class EmbeddingCache
    # One successful recorded embedding return.
    record CachedEmbedding,
      vectors : Array(Array(Float64)),
      requested_event_id : String?

    @by_hash = {} of String => CachedEmbedding

    # The stable content key for one embedding request (upstream
    # `hash_embedding_request`): SHA-256 of sorted-key compact JSON over
    # {model, texts}.
    def self.hash_embedding_request(texts : Array(String), model : String) : String
      canonical = JSON.build do |json|
        json.object do
          json.field "model", model
          json.field "texts", texts
        end
      end
      ContentHash.digest(canonical)
    end

    # Defensive vector copies for `inputs_hash`, or nil on a miss.
    def get(inputs_hash : String) : Array(Array(Float64))?
      entry = @by_hash[inputs_hash]?
      return nil if entry.nil?

      entry.vectors.map(&.dup)
    end

    # Whether a successful response is cached for `inputs_hash`.
    def has(inputs_hash : String) : Bool
      @by_hash.has_key?(inputs_hash)
    end

    # Number of cached entries.
    def size : Int32
      @by_hash.size
    end

    # Store an immutable copy of a validated embedding response.
    def record(inputs_hash : String, vectors : Array(Array(Float64)), *, requesting_event_id : String? = nil) : Nil
      @by_hash[inputs_hash] = CachedEmbedding.new(
        vectors.map(&.dup),
        requesting_event_id,
      )
    end

    # Harvest successful request/response pairs from an event log (upstream
    # `EmbeddingCache.from_events`): pairs `embedding.responded` (no error)
    # back to its `embedding.requested` via `caused_by`, keys on the request's
    # `inputs_hash`, and skips malformed responses / input-count mismatches.
    def self.from_events(events : Array(Event)) : self
      cache = new
      by_id = {} of String => Event
      events.each { |e| by_id[e.id] = e }

      events.each do |evt|
        harvest_one(cache, evt, by_id)
      end
      cache
    rescue JSON::ParseException
      cache || new
    end

    # Harvest one `embedding.responded` event into `cache` if it pairs to a
    # valid, error-free recorded request.
    private def self.harvest_one(cache : self, evt : Event, by_id : Hash(String, Event)) : Nil
      return unless evt.type == "embedding.responded"

      payload = JSON.parse(evt.payload).as_h
      return if error_present?(payload)

      pair = request_pair(evt, by_id)
      return if pair.nil?

      inputs_hash, input_count = pair
      vectors = payload["vectors"]?
      return if vectors.nil?

      hydrated = hydrate_vectors(vectors)
      return if hydrated.nil?

      return if input_count && hydrated.size != input_count

      cache.record(inputs_hash, hydrated, requesting_event_id: evt.caused_by)
    end

    # Resolve a responded event's recorded request pair `(inputs_hash,
    # input_count)`, or nil when the causal request is missing / not an
    # embedding.requested / carries no hash.
    private def self.request_pair(evt : Event, by_id : Hash(String, Event)) : {String, Int32?}?
      request_id = evt.caused_by
      return nil if request_id.nil?

      request = by_id[request_id]?
      return nil if request.nil? || request.type != "embedding.requested"

      request_payload = JSON.parse(request.payload).as_h
      inputs_hash = request_payload["inputs_hash"]?.try(&.as_s)
      return nil if inputs_hash.nil? || inputs_hash.empty?

      {inputs_hash, request_payload["input_count"]?.try(&.as_i)}
    end

    # True when the response payload carries a non-null `error`. The success
    # payload always has `"error": null`; only a non-nil value marks a failed
    # attempt. (`JSON::Any#nil?` reports the wrapper, not the raw value, so
    # compare the raw against nil.)
    private def self.error_present?(payload : Hash(String, JSON::Any)) : Bool
      error = payload["error"]?
      error ? !error.raw.nil? : false
    end

    # Validate + normalize a recorded vectors payload. Nil when malformed
    # (non-list vector, mixed dimensions, non-numeric / non-finite component).
    private def self.hydrate_vectors(raw : JSON::Any) : Array(Array(Float64))?
      list = raw.as_a?
      return nil if list.nil?

      out = [] of Array(Float64)
      dimensions : Int32? = nil
      list.each do |vector|
        row = vector.as_a?
        return nil if row.nil?

        if dims = dimensions
          return nil if row.size != dims
        else
          dimensions = row.size
        end

        hydrated = [] of Float64
        row.each do |value|
          number = value.as_f?
          return nil if number.nil? || !number.finite?

          hydrated << number
        end
        out << hydrated
      end
      out
    end
  end
end
