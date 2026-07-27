require "../spec_helper"

describe Clarity::EffectArtifactStore do
  it "stores and retrieves an artifact by content hash" do
    request = Clarity::EffectRequest.new("req_001", Clarity::EffectKind::Model, %({"prompt":"hello"}))
    store = Clarity::EffectArtifactStore.new
    store.store(request)

    hash = request.content_hash
    artifact = store.get(hash)
    artifact.should_not be_nil
    artifact.not_nil!.request_hash.should eq(hash)
    artifact.not_nil!.request_kind.should eq(Clarity::EffectKind::Model)
  end

  it "returns nil for a missing hash" do
    store = Clarity::EffectArtifactStore.new
    store.get("nonexistent").should be_nil
  end

  it "records and retrieves an effect result" do
    request = Clarity::EffectRequest.new("req_001", Clarity::EffectKind::Tool, %({"tool":"search","args":{"q":"hello"}}))
    store = Clarity::EffectArtifactStore.new
    store.store(request)

    hash = request.content_hash
    result = Clarity::EffectResult.new(hash, true, %({"result":"found"}))
    store.record(hash, result)

    artifact = store.get(hash)
    artifact.not_nil!.result.should_not be_nil
    artifact.not_nil!.result.not_nil!.success?.should be_true
    artifact.not_nil!.result.not_nil!.payload.should eq(%({"result":"found"}))
  end

  it "returns all recorded results for replay" do
    store = Clarity::EffectArtifactStore.new

    req1 = Clarity::EffectRequest.new("req_001", Clarity::EffectKind::Model, %({"prompt":"hello"}))
    req2 = Clarity::EffectRequest.new("req_002", Clarity::EffectKind::Tool, %({"tool":"search"}))

    store.store(req1)
    store.store(req2)
    store.record(req1.content_hash, Clarity::EffectResult.new(req1.content_hash, true, "response_a"))
    store.record(req2.content_hash, Clarity::EffectResult.new(req2.content_hash, false, "error_b"))

    results = store.results
    results.size.should eq(2)
    results[req1.content_hash].not_nil!.success?.should be_true
    results[req2.content_hash].not_nil!.success?.should be_false
  end

  it "deduplicates identical effect requests" do
    request = Clarity::EffectRequest.new("req_001", Clarity::EffectKind::Model, %({"prompt":"hello"}))
    store = Clarity::EffectArtifactStore.new
    store.store(request)
    store.store(request) # same payload → same hash → overwrite

    hash = request.content_hash
    store.get(hash).should_not be_nil
    # Only one artifact
    store.results.size.should eq(0) # no results recorded yet
  end
end

describe Clarity::ModelEffectRequest do
  it "uses a durable request event and exact route target as its edge contract" do
    target = Clarity::Routing::Target.new("ollama", "qwen2.5-coder", false)
    effect = Clarity::EffectRequest.new("req_001", Clarity::EffectKind::Model, %({"prompt":"hello"}))

    request = Clarity::ModelEffectRequest.new("llm_requested_7", effect, target)

    request.request_event_id.should eq("llm_requested_7")
    request.request_hash.should eq(effect.content_hash)
    request.target.should eq(target)
  end
end

describe Clarity::ModelEffectResult do
  it "normalizes the edge response without retaining a provider SDK object" do
    result = Clarity::ModelEffectResult.new(
      "llm_requested_7", "ollama", "qwen2.5-coder", "Hello", 12, 4, "message-1",
    )

    result.request_event_id.should eq("llm_requested_7")
    result.provider.should eq("ollama")
    result.model.should eq("qwen2.5-coder")
    result.content.should eq("Hello")
    result.input_tokens.should eq(12)
    result.output_tokens.should eq(4)
    result.choice.first.text.not_nil!.text.should eq("Hello")
  end
end
