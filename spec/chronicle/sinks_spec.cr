require "../spec_helper"
require "./sink_conformance"

# Sink specs. Ported from activegraph sinks/base.py + sinks/conformance.py
# (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616), adapted to the
# Sans-IO core (bounded queue drained by flush_sinks, no worker threads).
# TestingSink runs the reusable SinkConformance suite.

describe Chronicle::TestingSink do
  SinkConformance.define_tests(Chronicle::TestingSink.new("test"))
end

describe Chronicle::JSONLSink do
  it "writes canonical JSON lines to the IO" do
    io = IO::Memory.new
    sink = Chronicle::JSONLSink.new("jsonl", io)
    g = Chronicle::GraphProjection.empty
    g.add_sink(sink, name: "jsonl")

    g.emit(SinkConformanceFixture.event(1_u64, "evt_1"))
    g.flush_sinks

    lines = io.to_s.lines(chomp: true)
    lines.size.should eq(1)
    Chronicle::EventLogCodec::EventRecord.from_json(lines[0]).id.should eq("evt_1")
  end
end
