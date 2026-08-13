require "../spec_helper"

private def vectors(rows : Array(Array(Float64))) : JSON::Any
  JSON.parse(rows.to_json)
end

describe Chronicle::RuntimeReason do
  it "normalizes a well-formed batch embedding response (upstream _validate_embedding_vectors)" do
    texts = ["alpha", "beta"]
    result = Chronicle::RuntimeReason.validate_embedding_vectors(texts, vectors([[1.5, 2.0], [3.0, 4.25]]))
    result.should eq([[1.5, 2.0], [3.0, 4.25]])
  end

  it "rejects a wrong vector count" do
    expect_raises(ArgumentError, /wrong vector count.*expected 2, got 1/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha", "beta"], vectors([[1.0]]))
    end
  end

  it "rejects a non-list vectors value" do
    expect_raises(ArgumentError, /wrong vector count.*expected 1, got Hash/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha"], JSON.parse(%({"not":"a list"})))
    end
  end

  it "rejects a non-list vector element" do
    expect_raises(ArgumentError, /non-list vector/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha", "beta"], JSON.parse(%([[1.0], "oops"])))
    end
  end

  it "rejects mixed vector dimensions" do
    expect_raises(ArgumentError, /mixed vector dimensions/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha", "beta"], vectors([[1.0, 2.0], [3.0]]))
    end
  end

  it "rejects non-numeric vector components" do
    expect_raises(ArgumentError, /vector components must be numeric/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha"], JSON.parse(%([[1.0, "x"]])))
    end
    expect_raises(ArgumentError, /vector components must be numeric/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha"], JSON.parse(%([[true, 1.0]])))
    end
  end

  it "rejects non-finite vector components" do
    infinite = JSON::Any.new([JSON::Any.new([JSON::Any.new(1.0), JSON::Any.new(Float64::INFINITY)])])
    expect_raises(ArgumentError, /vector components must be finite/) do
      Chronicle::RuntimeReason.validate_embedding_vectors(["alpha"], infinite)
    end
  end

  it "returns an empty list for an empty batch" do
    Chronicle::RuntimeReason.validate_embedding_vectors([] of String, vectors([] of Array(Float64))).should be_empty
  end
end
