require "../spec_helper"

module ReplayStreamSpecHelper
  extend self

  def event(
    sequence : UInt64,
    id : String,
    type : String,
    payload : String,
    caused_by : String? = nil,
    actor : String = "test",
  ) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: sequence,
      id: id,
      type: type,
      actor: actor,
      caused_by: caused_by,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload
    )
  end
end

# Ports activegraph.runtime.runtime._verify_replay's stream comparison
# (runtime.py #L4180-L4368): strict replay compares the non-lifecycle
# (id, type) streams, excluding non-replayable failed LLM attempts, direct
# operator-embedding pairs, and promote blocks from the recorded side. The
# first divergence is pinned with emitted_expected/actual, not a generic
# sequence number.
describe Chronicle::ReplayEngine do
  it "raises a type-mismatch divergence pinned to the recorded event id" do
    goal = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    recorded = [
      goal,
      ReplayStreamSpecHelper.event(2_u64, "evt_000002", "tool.failed", %({"error":"boom"}), goal.id),
    ]
    emitted = [
      goal,
      ReplayStreamSpecHelper.event(2_u64, "evt_000002", "model.responded", %({"ok":true}), goal.id),
    ]

    error = expect_raises(Chronicle::ReplayDivergenceError) do
      Chronicle::ReplayEngine.new.replay(recorded, Chronicle::ReplayMode::Strict, emitted)
    end

    error.event_id.should eq("evt_000002")
    error.expected.should eq("tool.failed")
    error.actual.should eq("model.responded")
    error.kind.should eq("type_mismatch")
  end

  it "pins a length mismatch when the live re-run finishes early" do
    goal = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    recorded = [
      goal,
      ReplayStreamSpecHelper.event(2_u64, "evt_000002", "tool.failed", %({"error":"boom"}), goal.id),
    ]

    error = expect_raises(Chronicle::ReplayDivergenceError) do
      Chronicle::ReplayEngine.new.replay(recorded, Chronicle::ReplayMode::Strict, [goal])
    end

    error.event_id.should eq("evt_000002")
    error.expected.should eq("tool.failed")
    error.actual.should be_nil
    error.kind.should eq("length_mismatch")
  end

  it "pins a length mismatch when the live re-run produced an unrecorded event" do
    goal = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    emitted = [
      goal,
      ReplayStreamSpecHelper.event(2_u64, "evt_000002", "tool.failed", %({"error":"boom"}), goal.id),
    ]

    error = expect_raises(Chronicle::ReplayDivergenceError) do
      Chronicle::ReplayEngine.new.replay([goal], Chronicle::ReplayMode::Strict, emitted)
    end

    error.event_id.should eq("evt_000002")
    error.expected.should eq("<no recorded event>")
    error.actual.should eq("tool.failed")
    error.kind.should eq("length_mismatch")
  end

  it "ignores payload differences between matching stream positions" do
    # Upstream compares (id, type) streams only; the prompt-hash/embedding-hash
    # checks live in the cache wiring, not the stream comparator.
    expected = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    actual = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"two"}))

    result = Chronicle::ReplayEngine.new.replay([expected], Chronicle::ReplayMode::Strict, [actual])

    result.projection.all_objects.should be_empty
  end

  it "excludes failed LLM attempt pairs from the recorded stream" do
    # A transient provider failure followed by a successful retry: the failed
    # request/response pair is NOT deterministic replay output, so it is
    # excluded from the recorded stream and the replayed success aligns.
    goal = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    failed_request = ReplayStreamSpecHelper.event(2_u64, "evt_000002", "llm.requested", %({"prompt_hash":"abc"}), goal.id)
    llm_failed = ReplayStreamSpecHelper.event(3_u64, "evt_000003", "llm.failed", %({"reason":"network"}), failed_request.id)
    retry_request = ReplayStreamSpecHelper.event(4_u64, "evt_000004", "llm.requested", %({"prompt_hash":"abc"}), goal.id)
    llm_responded = ReplayStreamSpecHelper.event(5_u64, "evt_000005", "llm.responded", %({"output":"ok"}), retry_request.id)

    recorded = [goal, failed_request, llm_failed, retry_request, llm_responded]
    emitted = [
      goal,
      ReplayStreamSpecHelper.event(2_u64, "evt_000004", "llm.requested", %({"prompt_hash":"abc"}), goal.id),
      ReplayStreamSpecHelper.event(3_u64, "evt_000005", "llm.responded", %({"output":"ok"}), "evt_000004"),
    ]

    result = Chronicle::ReplayEngine.new.replay(recorded, Chronicle::ReplayMode::Strict, emitted)

    result.projection.all_objects.should be_empty
  end

  it "excludes direct (operator-invoked) embedding pairs from the recorded stream" do
    goal = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    emb_request = ReplayStreamSpecHelper.event(2_u64, "evt_000002", "embedding.requested", %({"inputs_hash":"xyz"}))
    emb_response = ReplayStreamSpecHelper.event(3_u64, "evt_000003", "embedding.responded", %({"vector":[0.1]}), emb_request.id)

    result = Chronicle::ReplayEngine.new.replay(
      [goal, emb_request, emb_response],
      Chronicle::ReplayMode::Strict,
      [goal]
    )

    result.projection.all_objects.should be_empty
  end

  it "excludes promote blocks from both compared streams" do
    goal = ReplayStreamSpecHelper.event(1_u64, "evt_000001", "goal.created", %({"goal":"one"}))
    marker = ReplayStreamSpecHelper.event(2_u64, "evt_000002", "promote.applied", %({"lib_key":"pack.tool"}), actor: "runtime")
    promoted = ReplayStreamSpecHelper.event(
      3_u64, "evt_000003", "patch.applied",
      %({"patch":{"id":"patch_1","target":"claim#5","op":"create","value":{"text":"t"},"expected_version":0,"proposed_by":"promote:pack.tool"},"target":"claim#5"}),
      marker.id, actor: "promote:pack.tool"
    )
    derived = ReplayStreamSpecHelper.event(4_u64, "evt_000004", "model.responded", %({"ok":true}), promoted.id)

    recorded = [goal, marker, promoted, derived]
    emitted = [
      goal,
      ReplayStreamSpecHelper.event(2_u64, "evt_000002", "promote.applied", %({"lib_key":"pack.tool"}), actor: "runtime"),
      ReplayStreamSpecHelper.event(4_u64, "evt_000004", "model.responded", %({"ok":true}), "evt_000003"),
    ]

    result = Chronicle::ReplayEngine.new.replay(recorded, Chronicle::ReplayMode::Strict, emitted)

    result.projection.all_objects.should be_empty
  end
end
