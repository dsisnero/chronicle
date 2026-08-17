require "../spec_helper"

# EmbeddingCache — the content-keyed replay cache for runtime-owned embedding
# calls (CONTRACT v1.8 #6, upstream llm/embedding_cache.py). Requests are
# keyed by canonical input content (model + ordered texts); successful
# recorded returns hydrate a fresh runtime; cache reads return defensive
# copies so callers cannot mutate the replay authority.

describe Chronicle::EmbeddingCache do
  describe ".hash_embedding_request" do
    it "is stable and content-keyed" do
      h1 = Chronicle::EmbeddingCache.hash_embedding_request(["alpha", "beta"], "test-embedding-v1")
      h2 = Chronicle::EmbeddingCache.hash_embedding_request(["alpha", "beta"], "test-embedding-v1")
      h1.should eq(h2)
      h1.size.should eq(64)
    end

    it "distinguishes model and text order" do
      Chronicle::EmbeddingCache.hash_embedding_request(["alpha"], "a").should_not eq(
        Chronicle::EmbeddingCache.hash_embedding_request(["alpha"], "b")
      )
      Chronicle::EmbeddingCache.hash_embedding_request(["a", "b"], "m").should_not eq(
        Chronicle::EmbeddingCache.hash_embedding_request(["b", "a"], "m")
      )
    end
  end

  describe "#get/#has/#size/#record" do
    it "records and returns defensive vector copies" do
      cache = Chronicle::EmbeddingCache.new
      cache.record("h", [[1.0, 2.0], [3.0, 4.0]], requesting_event_id: "evt_1")
      cache.has("h").should be_true
      cache.size.should eq(1)

      first = cache.get("h").not_nil!
      first[0][0] = 999.0
      cache.get("h").should eq([[1.0, 2.0], [3.0, 4.0]])
    end

    it "returns nil for a miss" do
      cache = Chronicle::EmbeddingCache.new
      cache.get("missing").should be_nil
      cache.has("missing").should be_false
    end
  end

  describe ".from_events" do
    it "harvests recorded requested/responded pairs defensively" do
      events = embedding_pair(
        inputs_hash: "h",
        input_count: 2,
        vectors: [[1.0, 2.0], [3.0, 4.0]],
      )
      cache = Chronicle::EmbeddingCache.from_events(events)
      cached = cache.get("h")
      cached.should eq([[1.0, 2.0], [3.0, 4.0]])
      cached.not_nil![0][0] = 999.0
      cache.get("h").should eq([[1.0, 2.0], [3.0, 4.0]])
    end

    it "skips error-shaped responded events" do
      request = embedding_request_event("h", 1)
      response = Chronicle::Event.new(
        schema_version: 1_u16, sequence: 2_u64, id: "embedding_responded_2",
        type: "embedding.responded", actor: "runtime", caused_by: request.id,
        timestamp: Time.utc,
        payload: %({"inputs_hash":"h","model":"m","vectors":null,"cache_hit":false,"error":{"type":"RuntimeError","message":"boom"}}),
      )
      Chronicle::EmbeddingCache.from_events([request, response]).size.should eq(0)
    end

    it "skips a responded event whose vectors do not match the input count" do
      events = embedding_pair(
        inputs_hash: "h",
        input_count: 2,
        vectors: [[1.0]],
      )
      Chronicle::EmbeddingCache.from_events(events).size.should eq(0)
    end

    it "skips a responded event with malformed vectors" do
      request = embedding_request_event("h", 1)
      response = Chronicle::Event.new(
        schema_version: 1_u16, sequence: 2_u64, id: "embedding_responded_2",
        type: "embedding.responded", actor: "runtime", caused_by: request.id,
        timestamp: Time.utc,
        payload: %({"inputs_hash":"h","model":"m","vectors":[["not-a-number"]],"cache_hit":false,"error":null}),
      )
      Chronicle::EmbeddingCache.from_events([request, response]).size.should eq(0)
    end

    it "skips a responded event without a matching requested event" do
      response = Chronicle::Event.new(
        schema_version: 1_u16, sequence: 2_u64, id: "embedding_responded_2",
        type: "embedding.responded", actor: "runtime", caused_by: "missing_request",
        timestamp: Time.utc,
        payload: %({"inputs_hash":"h","model":"m","vectors":[[1.0]],"cache_hit":false,"error":null}),
      )
      Chronicle::EmbeddingCache.from_events([response]).size.should eq(0)
    end
  end
end

private def embedding_request_event(inputs_hash : String, input_count : Int32) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: "embedding_requested_1",
    type: "embedding.requested", actor: "runtime", caused_by: nil,
    timestamp: Time.utc,
    payload: JSON.build do |json|
      json.object do
        json.field "inputs_hash", inputs_hash
        json.field "model", "test-embedding-v1"
        json.field "input_count", input_count
        json.field "cache_hit", false
      end
    end,
  )
end

private def embedding_pair(inputs_hash : String, input_count : Int32, vectors : Array(Array(Float64))) : Array(Chronicle::Event)
  request = embedding_request_event(inputs_hash, input_count)
  response = Chronicle::Event.new(
    schema_version: 1_u16, sequence: 2_u64, id: "embedding_responded_2",
    type: "embedding.responded", actor: "runtime", caused_by: request.id,
    timestamp: Time.utc,
    payload: JSON.build do |json|
      json.object do
        json.field "inputs_hash", inputs_hash
        json.field "model", "test-embedding-v1"
        json.field "vectors", vectors
        json.field "vector_count", vectors.size
        json.field "dimensions", vectors.first?.try(&.size) || 0
        json.field "cache_hit", false
        json.field "error", nil
      end
    end,
  )
  [request, response]
end
