require "../spec_helper"

module ReplaySpecHelper
  extend self

  def event(sequence : UInt64, id : String, type : String, payload : String, caused_by : String? = nil) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: sequence,
      id: id,
      type: type,
      actor: "test",
      caused_by: caused_by,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload
    )
  end
end

describe Chronicle::ReplayEngine do
  it "serves recorded effect results during permissive replay" do
    request = ReplaySpecHelper.event(
      1_u64,
      "evt_000001",
      "effect.requested",
      %({"hash":"abc123","kind":"tool"})
    )
    response = ReplaySpecHelper.event(
      2_u64,
      "evt_000002",
      "effect.responded",
      %({"hash":"abc123","success":true,"payload":{"status":"ok"}}),
      request.id
    )

    result = Chronicle::ReplayEngine.new.replay([request, response], Chronicle::ReplayMode::Permissive)

    result.effects["abc123"].success?.should be_true
    result.effects["abc123"].payload.should eq(%({"status":"ok"}))
  end

  it "ignores payload differences at matching stream positions during strict replay" do
    # Upstream _verify_replay compares (id, type) streams, not payloads; the
    # prompt/embedding hash checks live in the cache wiring, and the stream
    # comparator tracks divergence in structure (types and length) only.
    expected = ReplaySpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    actual = ReplaySpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"two"}))

    result = Chronicle::ReplayEngine.new.replay([expected], Chronicle::ReplayMode::Strict, [actual])

    result.projection.all_objects.should be_empty
  end

  it "replays from an artifact store instead of parsing effect.responded events" do
    # Build an artifact store with pre-recorded results
    store = Chronicle::EffectArtifactStore.new
    request = Chronicle::EffectRequest.new("req_001", Chronicle::EffectKind::Tool, %({"tool":"ping"}))
    store.store(request)
    store.record(request.content_hash, Chronicle::EffectResult.new(request.content_hash, true, %({"pong":true})))

    # Events — no effect.responded events, only the request
    event = ReplaySpecHelper.event(
      1_u64, "evt_000001", "effect.requested",
      %({"hash":"#{request.content_hash}","kind":"tool"})
    )

    result = Chronicle::ReplayEngine.new.replay([event], Chronicle::ReplayMode::Permissive, store: store)

    result.effects[request.content_hash].should_not be_nil
    result.effects[request.content_hash].success?.should be_true
  end

  it "falls back to event-parsed results when no store is given" do
    request = ReplaySpecHelper.event(
      1_u64, "evt_000001", "effect.requested",
      %({"hash":"abc123","kind":"tool"})
    )
    response = ReplaySpecHelper.event(
      2_u64, "evt_000002", "effect.responded",
      %({"hash":"abc123","success":true,"payload":{"status":"ok"}}),
      request.id
    )

    result = Chronicle::ReplayEngine.new.replay([request, response], Chronicle::ReplayMode::Permissive)

    result.effects["abc123"].success?.should be_true
  end

  it "accepts an identical emitted stream during strict replay" do
    event = ReplaySpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))

    result = Chronicle::ReplayEngine.new.replay([event], Chronicle::ReplayMode::Strict, [event])

    result.projection.all_objects.should be_empty
  end
end
