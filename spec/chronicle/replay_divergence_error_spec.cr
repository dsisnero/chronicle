require "../spec_helper"

# Structured ReplayDivergenceError message builders (CONTRACT v1.0 #C1,
# CONTRACT v0.5 #7). Ported from activegraph.runtime.errors — the reference
# error class for the v1.0 message rewrite series. The signature
# `(event_id:, expected:, actual:)` is preserved; the discriminator is
# inferred from the inputs:
#
#   - expected starts with "prompt_hash="    -> prompt_hash_mismatch
#   - expected starts with "embedding_hash=" -> embedding_hash_mismatch
#   - expected == "<no recorded event>" or actual is nil -> length_mismatch
#   - otherwise -> type_mismatch
#
# The legacy message-plus-attrs single-arg constructor keeps working for
# back-compat call sites.

private def structured(event_id : String, expected : String, actual : String?) : Chronicle::ReplayDivergenceError
  Chronicle::ReplayDivergenceError.new(event_id: event_id, expected: expected, actual: actual)
end

describe Chronicle::ReplayDivergenceError do
  describe "structured construction (upstream _build_message discriminator)" do
    it "builds a prompt_hash_mismatch when expected starts with prompt_hash=" do
      err = structured("evt_042", "prompt_hash=a1b2c3", "prompt_hash=z9y8x7")
      err.kind.should eq("prompt_hash_mismatch")
      err.event_id.should eq("evt_042")
      err.expected.should eq("prompt_hash=a1b2c3")
      err.actual.should eq("prompt_hash=z9y8x7")
      err.structured?.should be_true
      err.context["kind"].as_s.should eq("prompt_hash_mismatch")
      err.context["event_id"].as_s.should eq("evt_042")
      err.to_s.should contain("replay diverged at evt_042: LLM prompt hash mismatch")
      err.to_s.should contain("recorded:  prompt_hash=a1b2c3")
      err.to_s.should contain("live:      prompt_hash=z9y8x7")
    end

    it "renders <no live response> when the actual hash is absent" do
      err = structured("evt_1", "prompt_hash=a1b2c3", nil)
      err.kind.should eq("prompt_hash_mismatch")
      err.to_s.should contain("live:      <no live response>")
      err.actual.should be_nil
    end

    it "builds an embedding_hash_mismatch when expected starts with embedding_hash=" do
      err = structured("evt_077", "embedding_hash=d0g", "embedding_hash=c4t")
      err.kind.should eq("embedding_hash_mismatch")
      err.to_s.should contain("replay diverged at evt_077: embedding input hash mismatch")
      err.to_s.should contain("recorded:  embedding_hash=d0g")
      err.to_s.should contain("live:      embedding_hash=c4t")
      err.context["kind"].as_s.should eq("embedding_hash_mismatch")
    end

    it "builds a length_mismatch when there is no recorded event to compare" do
      err = structured("evt_9", "<no recorded event>", "object.created")
      err.kind.should eq("length_mismatch")
      err.to_s.should contain("replay diverged at evt_9: live re-run produced an unrecorded event")
      err.to_s.should contain("recorded:  <no event recorded>")
    end

    it "builds a length_mismatch when the live re-run finished early (actual nil)" do
      err = structured("evt_9", "object.created", nil)
      err.kind.should eq("length_mismatch")
      err.to_s.should contain("replay diverged at evt_9: live re-run finished early")
      err.to_s.should contain("live:      <no event produced>")
    end

    it "builds a type_mismatch otherwise" do
      err = structured("evt_042", "relation.created", "object.created")
      err.kind.should eq("type_mismatch")
      err.to_s.should contain("replay diverged at evt_042: event type mismatch")
      err.to_s.should contain("recorded:  \"relation.created\"")
      err.to_s.should contain("live:      \"object.created\"")
      err.context["expected"].as_s.should eq("relation.created")
    end
  end

  describe "structured format compliance" do
    it "obeys the locked ActiveGraphError format" do
      err = structured("evt_042", "relation.created", "object.created")
      msg = err.to_s
      msg.should start_with("ReplayDivergenceError: replay diverged at evt_042: event type mismatch\n")
      ["What failed:", "Why:", "How to fix:", "More:"].each { |header| msg.should contain("\n#{header}\n") }
      msg.should contain("More:\n  https://docs.activegraph.ai/errors/replay-divergence-error")
    end
  end

  describe "legacy signature back-compat" do
    it "preserves the message-plus-attrs constructor" do
      err = Chronicle::ReplayDivergenceError.new(
        "replay diverged",
        event_id: "evt_042",
        expected: "prompt_hash=a1b2c3",
        actual: "prompt_hash=z9y8x7",
      )
      err.event_id.should eq("evt_042")
      err.expected.should eq("prompt_hash=a1b2c3")
      err.actual.should eq("prompt_hash=z9y8x7")
      err.to_s.should eq("replay diverged")
      err.structured?.should be_false
    end

    it "keeps plain single-arg construction verbatim" do
      err = Chronicle::ReplayDivergenceError.new("invalid recorded effect result")
      err.to_s.should eq("invalid recorded effect result")
    end
  end

  describe "message builder (upstream runtime/errors.py)" do
    it "exposes build_message returning kind/summary/what_failed/why/how_to_fix" do
      built = Chronicle::ReplayDivergenceError.build_message(
        event_id: "evt_042",
        expected: "object.created",
        actual: "relation.created",
      )
      built[:kind].should eq("type_mismatch")
      built[:summary].should eq("replay diverged at evt_042: event type mismatch")
      built[:what_failed].should_not be_empty
      built[:why].should_not be_empty
      built[:how_to_fix].should_not be_empty
    end
  end
end
