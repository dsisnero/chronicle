require "../spec_helper"

# Sink specs. Ported from activegraph sinks/base.py + sinks/conformance.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed), adapted to the
# Sans-IO core (bounded queue drained by flush_sinks, no worker threads).

module SinkSpecHelper
  extend self

  def event(seq : UInt64, id : String, data : String = %({"k":"v"})) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16, sequence: seq, id: id,
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"id":"obj_#{seq}","type":"task","data":#{data}}),
    )
  end
end

describe Clarity::TestingSink do
  it "collects offered events in order after flush" do
    sink = Clarity::TestingSink.new("test")
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "test")

    g.emit(SinkSpecHelper.event(1_u64, "evt_1"))
    g.emit(SinkSpecHelper.event(2_u64, "evt_2"))
    g.flush_sinks

    sink.events.map(&.id).should eq(["evt_1", "evt_2"])
  end

  it "delivers the delivery context with each event" do
    sink = Clarity::TestingSink.new("test")
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "test")
    g.emit(SinkSpecHelper.event(1_u64, "evt_1"))
    g.flush_sinks

    ctx = sink.contexts[0]
    ctx.sequence.should eq(1_u64)
    ctx.mode.should eq("live")
  end

  it "counts bounded overflow under drop_newest" do
    sink = Clarity::TestingSink.new("test")
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "test", queue_capacity: 2)

    3.times { |i| g.emit(SinkSpecHelper.event((i + 1).to_u64, "evt_#{i + 1}")) }
    g.flush_sinks

    # queue held 2; the third offer was dropped.
    sink.events.size.should eq(2)
    status = g.sink_statuses["test"]
    status.dropped.should eq(1)
    status.enqueued.should eq(3)
    status.delivered.should eq(2)
  end

  it "reports sink status" do
    sink = Clarity::TestingSink.new("test")
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "test", queue_capacity: 4)

    status = g.sink_statuses["test"]
    status.queue_capacity.should eq(4)
    status.queue_depth.should eq(0)
  end

  it "stops delivering after remove_sink" do
    sink = Clarity::TestingSink.new("test")
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "test")
    g.remove_sink("test")

    g.emit(SinkSpecHelper.event(1_u64, "evt_1"))
    g.flush_sinks

    sink.events.should be_empty
    g.sink_statuses.has_key?("test").should be_false
  end

  it "round-trips unicode payloads" do
    sink = Clarity::TestingSink.new("test")
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "test")
    data = %({"nested":{"k":[1,2,{"a":"b"}]},"unicode":"café — 🚀"})
    g.emit(SinkSpecHelper.event(1_u64, "evt_1", data))
    g.flush_sinks

    sink.events[0].payload.should contain("café — 🚀")
  end
end

describe Clarity::JSONLSink do
  it "writes canonical JSON lines to the IO" do
    io = IO::Memory.new
    sink = Clarity::JSONLSink.new("jsonl", io)
    g = Clarity::GraphProjection.empty
    g.add_sink(sink, name: "jsonl")

    g.emit(SinkSpecHelper.event(1_u64, "evt_1"))
    g.flush_sinks

    lines = io.to_s.lines(chomp: true)
    lines.size.should eq(1)
    Clarity::EventLogCodec::EventRecord.from_json(lines[0]).id.should eq("evt_1")
  end
end
