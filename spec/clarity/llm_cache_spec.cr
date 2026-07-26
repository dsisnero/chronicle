require "../spec_helper"

private def make_request_event(seq, id, hash)
  Clarity::Event.new(
    schema_version: 1_u16, sequence: seq, id: id,
    type: "effect.requested", actor: "test", caused_by: nil,
    timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
    payload: %({"hash":"#{hash}","kind":"model"}),
  )
end

private def make_response_event(seq, id, hash, caused_by)
  Clarity::Event.new(
    schema_version: 1_u16, sequence: seq, id: id,
    type: "effect.responded", actor: "test", caused_by: caused_by,
    timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
    payload: %({"hash":"#{hash}","success":true,"payload":{"text":"hello"}}),
  )
end

describe Clarity::LLMCache do
  it "is initially empty" do
    cache = Clarity::LLMCache.new
    cache.size.should eq(0)
  end

  it "records and retrieves a response by hash" do
    cache = Clarity::LLMCache.new
    result = Clarity::EffectResult.new("abc123", true, %({"text":"hello"}))

    cache.record("abc123", result)
    cached = cache.get("abc123")
    cached.should_not be_nil
    cached.not_nil!.payload.should eq(%({"text":"hello"}))
  end

  it "returns nil for a missing hash" do
    cache = Clarity::LLMCache.new
    cache.get("nonexistent").should be_nil
  end

  it "populates from a sequence of effect.requested + effect.responded events" do
    events = [
      make_request_event(1_u64, "req_001", "hash_a"),
      make_response_event(2_u64, "resp_001", "hash_a", "req_001"),
      make_request_event(3_u64, "req_002", "hash_b"),
      make_response_event(4_u64, "resp_002", "hash_b", "req_002"),
    ]

    cache = Clarity::LLMCache.from_events(events)
    cache.size.should eq(2)
    cache.get("hash_a").should_not be_nil
    cache.get("hash_b").should_not be_nil
  end

  it "skips failed responses" do
    failed = Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "resp_err",
      type: "effect.responded", actor: "test", caused_by: "req_err",
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"hash":"bad","success":false,"payload":{"error":"timeout"}}),
    )
    events = [failed]
    cache = Clarity::LLMCache.from_events(events)
    cache.size.should eq(0)
  end

  it "serves cached responses during replay" do
    cache = Clarity::LLMCache.new
    effect = Clarity::EffectResult.new("abc123", true, %({"text":"cached"}))

    cache.record("abc123", effect)
    engine = Clarity::ReplayEngine.new

    events = [] of Clarity::Event
    replay_result = engine.replay(events, Clarity::ReplayMode::Permissive, [] of Clarity::Event, nil, cache)
    replay_result.effects["abc123"].should_not be_nil
    replay_result.effects["abc123"].payload.should eq(%({"text":"cached"}))
  end
end
