require "../spec_helper"

# runtime.snapshot trace line. Ported from activegraph trace/printer.py
# `_fmt_runtime_snapshot` (CONTRACT v1.5 #2): the compaction boundary renders
# as one `[runtime.snapshot]` line — `N events compacted (state <hash19>)`.

module RuntimeSnapshotTraceFixture
  extend self

  def snapshot_event(payload : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: 99_u64, id: "runtime_snapshot_99",
      type: "runtime.snapshot", actor: "runtime", caused_by: nil,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: payload,
    )
  end
end

describe Chronicle::Trace do
  it "renders the runtime.snapshot compaction boundary line" do
    event = RuntimeSnapshotTraceFixture.snapshot_event(
      %({"state_hash":"sha256:abcdef0123456789abcdef0123456789abcdef0123456789","covers_through":"evt_50","events_covered":50,"id_counters":{"object":50}})
    )
    line = Chronicle::Trace.format_event(event)
    line.should contain("[runtime.snapshot]")
    line.should contain("50 events compacted")
    # Upstream truncates the full hash to its first 19 chars: `sha256:abcdef012345`.
    line.should contain("(state sha256:abcdef012345…)")
  end

  it "renders the singular event count" do
    event = RuntimeSnapshotTraceFixture.snapshot_event(
      %({"state_hash":"sha256:abcdef0123456789abcdef0123456789abcdef0123456789","events_covered":1})
    )
    line = Chronicle::Trace.format_event(event)
    line.should contain("1 event compacted")
  end

  it "tolerates a missing state_hash" do
    event = RuntimeSnapshotTraceFixture.snapshot_event(
      %({"events_covered":5})
    )
    line = Chronicle::Trace.format_event(event)
    line.should contain("5 events compacted")
  end
end
