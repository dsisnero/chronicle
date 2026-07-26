require "../spec_helper"

module ReplaySpecHelper
  extend self

  def event(sequence : UInt64, id : String, type : String, payload : String, caused_by : String? = nil) : Clarity::Event
    Clarity::Event.new(
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

describe Clarity::ReplayEngine do
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

    result = Clarity::ReplayEngine.new.replay([request, response], Clarity::ReplayMode::Permissive)

    result.effects["abc123"].success?.should be_true
    result.effects["abc123"].payload.should eq(%({"status":"ok"}))
  end

  it "raises at the first divergence during strict replay" do
    expected = ReplaySpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    actual = ReplaySpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"two"}))

    expect_raises(Clarity::ReplayDivergenceError, "replay diverged at sequence 1") do
      Clarity::ReplayEngine.new.replay([expected], Clarity::ReplayMode::Strict, [actual])
    end
  end

  it "replays from an artifact store instead of parsing effect.responded events" do
    # Build an artifact store with pre-recorded results
    store = Clarity::EffectArtifactStore.new
    request = Clarity::EffectRequest.new("req_001", Clarity::EffectKind::Tool, %({"tool":"ping"}))
    store.store(request)
    store.record(request.content_hash, Clarity::EffectResult.new(request.content_hash, true, %({"pong":true})))

    # Events — no effect.responded events, only the request
    event = ReplaySpecHelper.event(
      1_u64, "evt_000001", "effect.requested",
      %({"hash":"#{request.content_hash}","kind":"tool"})
    )

    result = Clarity::ReplayEngine.new.replay([event], Clarity::ReplayMode::Permissive, store: store)

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

    result = Clarity::ReplayEngine.new.replay([request, response], Clarity::ReplayMode::Permissive)

    result.effects["abc123"].success?.should be_true
  end

  it "accepts an identical emitted stream during strict replay" do
    event = ReplaySpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))

    result = Clarity::ReplayEngine.new.replay([event], Clarity::ReplayMode::Strict, [event])

    result.projection.objects.should be_empty
  end
end
