require "../spec_helper"

describe Chronicle::RuntimeReason do
  it "renders now_iso as a UTC ISO-8601 second-precision timestamp with a Z suffix" do
    value = Chronicle::RuntimeReason.now_iso
    value.should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
  end

  it "returns a monotonic clock value in fractional seconds" do
    a = Chronicle::RuntimeReason.monotonic
    b = Chronicle::RuntimeReason.monotonic
    b.should be >= a
  end

  it "keeps now_iso stable under a recorded provider (single source of truth)" do
    dir = pack_spec_dir("now_iso_single_source")
    # The recorded providers' now_iso delegates to RuntimeReason.now_iso.
    Chronicle::ToolRecorded.now_iso.should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    Chronicle::RuntimeReason.now_iso.should eq(Chronicle::ToolRecorded.now_iso)
  end
end
