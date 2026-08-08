require "../spec_helper"

private SECTIONS = ["What failed:", "Why:", "How to fix:", "More:"]

private def make_dummy(cls : T.class) : T forall T
  cls.new(
    "summary line for the snapshot",
    what_failed: "the specific thing that broke (with a name)",
    why: "the root cause, in one sentence",
    how_to_fix: "run the canonical fix command",
  )
end

private def assert_format_compliant(err : Chronicle::ActiveGraphError) : Nil
  msg = err.to_s
  first = msg.split("\n", 2).first
  first.should contain(": ")
  class_name = first.split(": ", 2).first
  class_name.should eq(err.class.to_s.split("::").last)
  first.split(": ", 2)[1].should_not be_empty

  positions = SECTIONS.map { |header| msg.index("\n#{header}\n").not_nil! }
  positions.should eq(positions.sort)

  SECTIONS[0..-2].each do |header|
    body = msg.split("\n#{header}\n", 2)[1].split("\n\n", 2).first
    body.should start_with("  ")
  end

  more_body = msg.split("\nMore:\n  ", 2)[1].strip
  more_body.should start_with("https://")
end

describe Chronicle::ActiveGraphError do
  describe "the seven category bases" do
    {% for cls in [Chronicle::ConfigurationError, Chronicle::RegistrationError, Chronicle::ExecutionError, Chronicle::ReplayError, Chronicle::StorageError, Chronicle::PatternError, Chronicle::PackError] %}
      it "{{ cls.name.split("::").last.id }} obeys the locked format (test_every_category_base_obeys_format)" do
        assert_format_compliant(make_dummy({{ cls }}))
      end
    {% end %}

    it "every category base exposes structured fields and a doc_url (test_every_category_base_exposes_structured_fields)" do
      err = make_dummy(Chronicle::ConfigurationError)
      err.what_failed.should eq("the specific thing that broke (with a name)")
      err.why.should eq("the root cause, in one sentence")
      err.how_to_fix.should eq("run the canonical fix command")
      err.context.should be_empty
      err.doc_url.should start_with("https://")
      err.doc_url.should end_with("/errors/configuration-error")
    end

    it "ActiveGraphError is the root of every category base (test_active_graph_error_is_the_root)" do
      {% for cls in [Chronicle::ConfigurationError, Chronicle::RegistrationError, Chronicle::ExecutionError, Chronicle::ReplayError, Chronicle::StorageError, Chronicle::PatternError, Chronicle::PackError] %}
        ({{ cls }} <= Chronicle::ActiveGraphError).should be_true
      {% end %}
    end

    it "every category base has a unique doc slug (test_doc_slug_is_unique_per_category)" do
      slugs = [
        Chronicle::ConfigurationError.doc_slug,
        Chronicle::RegistrationError.doc_slug,
        Chronicle::ExecutionError.doc_slug,
        Chronicle::ReplayError.doc_slug,
        Chronicle::StorageError.doc_slug,
        Chronicle::PatternError.doc_slug,
        Chronicle::PackError.doc_slug,
      ]
      slugs.size.should eq(slugs.uniq.size)
    end
  end

  describe "structured vs legacy construction" do
    it "renders the locked format when structured fields are supplied" do
      err = make_dummy(Chronicle::ReplayError)
      err.to_s.should contain("What failed:")
      err.to_s.should contain("Why:")
      err.to_s.should contain("How to fix:")
      err.to_s.should contain("More:\n  https://")
    end

    it "returns the message verbatim in legacy (single-arg) mode" do
      err = Chronicle::ReplayError.new("plain message")
      err.to_s.should eq("plain message")
      err.structured?.should be_false
    end

    it "is_structured is true when all three fields are populated" do
      make_dummy(Chronicle::ReplayError).structured?.should be_true
    end
  end

  describe "reference leaf: ReplayDivergenceError" do
    it "inherits from ReplayError (test_replay_divergence_inherits_from_replay_error)" do
      (Chronicle::ReplayDivergenceError <= Chronicle::ReplayError).should be_true
      (Chronicle::ReplayDivergenceError <= Chronicle::ActiveGraphError).should be_true
    end

    it "preserves the legacy signature attributes" do
      err = Chronicle::ReplayDivergenceError.new(
        "replay diverged",
        event_id: "evt_042",
        expected: "prompt_hash=a1b2c3",
        actual: "prompt_hash=z9y8x7",
      )
      err.event_id.should eq("evt_042")
      err.expected.should eq("prompt_hash=a1b2c3")
      err.actual.should eq("prompt_hash=z9y8x7")
    end
  end

  describe "internal_bug_fields" do
    it "produces uniform structured fields with a report URL" do
      fields = Chronicle::ActiveGraphError.internal_bug_fields(
        summary: "internal",
        what_happened: "bad",
        why_invariant: "invariant",
        location: "runtime/patterns.cr:42",
      )
      fields["summary"].should eq("internal")
      fields["what_failed"].should eq("bad")
      fields["context"].as_h["internal"].as_bool.should be_true
      fields["context"].as_h["internal_error_location"].as_s.should eq("runtime/patterns.cr:42")
      fields["context"].as_h.has_key?("report_url").should be_true
    end

    it "includes extra context keys" do
      fields = Chronicle::ActiveGraphError.internal_bug_fields(
        summary: "s",
        what_happened: "w",
        why_invariant: "y",
        location: "l",
        extra_context: {"operator" => JSON::Any.new("unknown")},
      )
      fields["context"].as_h["operator"].as_s.should eq("unknown")
    end
  end
end
