require "digest/sha256"
require "crig"

module Chronicle
  # The EmbeddingProvider protocol (v1.3, runtime-owned in v1.8). Mirrors
  # `LLMProvider`'s conventions: keyword-style arguments, an explicit `model`,
  # and a `default_model` for callers that don't pin one. Deliberately
  # minimal — one method plus a default-model declaration, matching upstream
  # `llm/embedding.py`.
  #
  # Calls flow through `Runtime#embed` / `ctx.embed` so external I/O is
  # represented by `embedding.requested` / `embedding.responded` events and
  # can replay from recorded vectors. Calling a provider object directly
  # remains possible but forfeits that replay guarantee.
  abstract class EmbeddingProvider
    # The model name to use when a caller doesn't pin one (upstream
    # HashEmbeddingProvider's default).
    def default_model : String
      "hash-64"
    end

    # Embed `texts` into one vector per input, order-preserving. Every
    # returned vector must have the same dimensionality for a given `model`;
    # implementations should raise on failure rather than returning partial
    # results.
    abstract def embed(texts : Array(String), model : String) : Array(Array(Float64))
  end

  # Adapts a `Crig::Embeddings::EmbeddingModel` to the `EmbeddingProvider`
  # protocol, so real providers written against Crig's embedding seam plug
  # into the recorded/replayable `Runtime#embed` path.
  class CrigEmbeddingProvider(M) < EmbeddingProvider
    @default_model : String

    def initialize(@model : M, @default_model : String)
    end

    def default_model : String
      @default_model
    end

    def embed(texts : Array(String), model : String) : Array(Array(Float64))
      @model.embed_texts(texts).map(&.vec)
    end
  end

  # Deterministic, dependency-free `EmbeddingProvider` test double (upstream
  # `HashEmbeddingProvider`): embeds text by hashing whitespace-separated,
  # lowercased tokens into a fixed number of buckets and L2-normalizing the
  # result. Identical texts embed identically on every platform and run — no
  # network, no keys, no model weights. The vectors are NOT semantically
  # meaningful beyond token overlap; use it to test embedding plumbing
  # deterministically and wire a real provider for retrieval quality.
  #
  # Also implements Crig's `EmbeddingModel` seam (`max_documents` / `ndims` /
  # `embed_texts`), so it plugs directly into Crig vector stores.
  class HashEmbeddingProvider < EmbeddingProvider
    include Crig::Embeddings::EmbeddingModel

    getter default_model : String = "hash-64"

    def initialize(@dimensions : Int32 = 64)
      if @dimensions < 1
        raise ArgumentError.new("dimensions must be >= 1, got #{@dimensions}")
      end
    end

    def embed(texts : Array(String), model : String) : Array(Array(Float64))
      texts.map { |text| embed_one(text) }
    end

    # --- Crig EmbeddingModel seam ----------------------------------------

    def max_documents : Int32
      Int32::MAX
    end

    def ndims : Int32
      @dimensions
    end

    def embed_texts(texts : Enumerable(String)) : Array(Crig::Embeddings::Embedding)
      list = texts.to_a
      embed(list, default_model).map_with_index do |vec, index|
        Crig::Embeddings::Embedding.new(list[index], vec)
      end
    end

    # One L2-normalized bucket-count vector for a single input text.
    private def embed_one(text : String) : Array(Float64)
      vec = Array(Float64).new(@dimensions, 0.0)
      text.downcase.split.each do |token|
        digest = Digest::SHA256.digest(token)
        bucket = ((digest[0].to_u32 << 24) | (digest[1].to_u32 << 16) |
                  (digest[2].to_u32 << 8) | digest[3].to_u32) % @dimensions
        vec[bucket] += 1.0
      end
      norm = Math.sqrt(vec.sum { |v| v * v })
      return vec if norm == 0.0

      vec.map { |v| v / norm }
    end
  end
end
