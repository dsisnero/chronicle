require "../spec_helper"

# EmbeddingProvider seam (v1.3, runtime-owned in v1.8): the protocol, the
# deterministic HashEmbeddingProvider test double, and a Crig shim that
# adapts a `Crig::Embeddings::EmbeddingModel` to the protocol. Ported from
# activegraph tests/test_embedding_provider.py. The HashEmbeddingProvider is
# a shim over Crig's `EmbeddingModel` seam so it also plugs into Crig vector
# stores (ndims / max_documents / embed_text).

describe Chronicle::HashEmbeddingProvider do
  it "conforms to the EmbeddingProvider protocol" do
    provider = Chronicle::HashEmbeddingProvider.new
    provider.should be_a(Chronicle::EmbeddingProvider)
    provider.default_model.should eq("hash-64")
  end

  it "is deterministic and L2-normalized" do
    provider = Chronicle::HashEmbeddingProvider.new(dimensions: 32)
    a = provider.embed(["the teal bakery"], provider.default_model)
    b = provider.embed(["the teal bakery"], provider.default_model)
    a.should eq(b)
    a[0].size.should eq(32)
    norm = Math.sqrt(a[0].sum { |v| v * v })
    norm.should be_close(1.0, 1e-9)
  end

  it "preserves order and handles empty text as a zero vector" do
    provider = Chronicle::HashEmbeddingProvider.new(dimensions: 8)
    vecs = provider.embed(["alpha", "", "beta"], provider.default_model)
    vecs.size.should eq(3)
    vecs[1].should eq([0.0] * 8)
    vecs[0].should_not eq(vecs[2])
  end

  it "reflects token overlap in cosine similarity" do
    provider = Chronicle::HashEmbeddingProvider.new
    q, near, far = provider.embed(
      ["what color do I like", "my favorite color is teal", "quarterly revenue grew"],
      provider.default_model,
    )

    cos = ->(a : Array(Float64), b : Array(Float64)) {
      a.zip(b).sum { |x, y| x * y }
    }
    (cos.call(q, near) > cos.call(q, far)).should be_true
  end

  it "rejects non-positive dimensions" do
    expect_raises(ArgumentError, /dimensions/) do
      Chronicle::HashEmbeddingProvider.new(dimensions: 0)
    end
  end

  describe "Crig EmbeddingModel shim" do
    it "exposes ndims / max_documents and embed_text on the Crig seam" do
      provider = Chronicle::HashEmbeddingProvider.new(dimensions: 16)
      provider.ndims.should eq(16)
      provider.max_documents.should be >= 1

      embedding = provider.embed_text("hello world")
      embedding.should be_a(Crig::Embeddings::Embedding)
      embedding.vec.should eq(provider.embed(["hello world"], provider.default_model)[0])
      embedding.document.should eq("hello world")

      response = provider.embed_text_with_usage("hello")
      response.embeddings.size.should eq(1)
    end
  end
end

describe Chronicle::CrigEmbeddingProvider do
  it "adapts a Crig EmbeddingModel to the EmbeddingProvider protocol" do
    model = Chronicle::HashEmbeddingProvider.new(dimensions: 8)
    provider = Chronicle::CrigEmbeddingProvider(Crig::Embeddings::EmbeddingModel).new(model, "hash-64")
    provider.should be_a(Chronicle::EmbeddingProvider)
    provider.default_model.should eq("hash-64")

    vectors = provider.embed(["alpha", "beta"], "hash-64")
    vectors.size.should eq(2)
    vectors[0].size.should eq(8)
  end
end
