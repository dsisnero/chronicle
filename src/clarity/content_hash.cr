require "digest/sha256"

module Clarity
  # Stable SHA-256 hashing for already-canonical content and future requests.
  module ContentHash
    extend self

    def digest(canonical_bytes : String) : String
      Digest::SHA256.hexdigest(canonical_bytes)
    end
  end
end
