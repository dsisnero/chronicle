module Clarity
  # A stored effect artifact indexed by content hash.
  struct EffectArtifact
    getter request_hash : String
    getter request_kind : EffectKind
    getter request_payload : String
    getter result : EffectResult?

    def initialize(
      @request_hash : String,
      @request_kind : EffectKind,
      @request_payload : String,
      @result : EffectResult? = nil,
    )
    end
  end

  # Content-addressed store for effect artifacts.
  # Artifacts are stored by the SHA-256 hash of their request payload,
  # enabling deduplication and independent verification during replay.
  class EffectArtifactStore
    def initialize
      @artifacts = {} of String => EffectArtifact
    end

    # Register an effect request. If an artifact with the same hash
    # already exists, it is overwritten (idempotent).
    def store(request : EffectRequest) : Nil
      hash = request.content_hash
      @artifacts[hash] = EffectArtifact.new(
        request_hash: hash,
        request_kind: request.kind,
        request_payload: request.payload,
      )
    end

    # Record a result for a previously stored artifact.
    def record(hash : String, result : EffectResult) : Nil
      if artifact = @artifacts[hash]?
        @artifacts[hash] = EffectArtifact.new(
          request_hash: artifact.request_hash,
          request_kind: artifact.request_kind,
          request_payload: artifact.request_payload,
          result: result,
        )
      end
    end

    # Retrieve an artifact by its content hash.
    def get(hash : String) : EffectArtifact?
      @artifacts[hash]?
    end

    # All recorded results indexed by request hash.
    # Used during replay to reconstruct effect outcomes.
    def results : Hash(String, EffectResult)
      memo = {} of String => EffectResult
      @artifacts.each do |hash, artifact|
        if result = artifact.result
          memo[hash] = result
        end
      end
      memo
    end
  end
end
