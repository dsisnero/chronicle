require "../spec_helper"

# Reusable EventSink adapter conformance suite. Ported from activegraph
# sinks/conformance.py (CONTRACT v1.8 #5). A concrete sink gets full coverage
# by invoking `SinkConformance.define_tests` with an expression that yields a
# fresh, empty sink adapter inside each test. The thread-based
# "shared sink across concurrent runs" case is N/A for the Sans-IO single-
# threaded core.

module SinkConformanceFixture
  extend self

  def event(seq : UInt64, id : String, data : String = %({"k":"v"})) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: id,
      type: "object.created", actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: %({"id":"obj_#{seq}","type":"task","data":#{data}}),
    )
  end
end

module SinkConformance
  # `sink_factory` must be an expression producing a fresh, empty Sink. The
  # graph each test emits onto is also fresh.
  macro define_tests(sink_factory)
    it "collects offered events in order after flush" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.add_sink(sink, name: "test")

      g.emit(SinkConformanceFixture.event(1_u64, "evt_1"))
      g.emit(SinkConformanceFixture.event(2_u64, "evt_2"))
      g.flush_sinks

      sink.events.map(&.id).should eq(["evt_1", "evt_2"])
    end

    it "delivers the delivery context with each event" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.add_sink(sink, name: "test")
      g.emit(SinkConformanceFixture.event(1_u64, "evt_1"))
      g.flush_sinks

      ctx = sink.contexts[0]
      ctx.sequence.should eq(1_u64)
      ctx.mode.should eq("live")
    end

    it "counts bounded overflow under drop_newest" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.add_sink(sink, name: "test", queue_capacity: 2)

      3.times { |i| g.emit(SinkConformanceFixture.event((i + 1).to_u64, "evt_#{i + 1}")) }
      g.flush_sinks

      sink.events.size.should eq(2)
      status = g.sink_statuses["test"]
      status.dropped.should eq(1)
      status.enqueued.should eq(3)
      status.delivered.should eq(2)
    end

    it "reports sink status" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.add_sink(sink, name: "test", queue_capacity: 4)

      status = g.sink_statuses["test"]
      status.queue_capacity.should eq(4)
      status.queue_depth.should eq(0)
    end

    it "stops delivering after remove_sink" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.add_sink(sink, name: "test")
      g.remove_sink("test")

      g.emit(SinkConformanceFixture.event(1_u64, "evt_1"))
      g.flush_sinks

      sink.events.should be_empty
      g.sink_statuses.has_key?("test").should be_false
    end

    it "round-trips unicode payloads" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.add_sink(sink, name: "test")
      data = %({"nested":{"k":[1,2,{"a":"b"}]},"unicode":"café — 🚀"})
      g.emit(SinkConformanceFixture.event(1_u64, "evt_1", data))
      g.flush_sinks

      sink.events[0].payload.should contain("café — 🚀")
    end

    it "isolates a raising sibling sink" do
      good = {{sink_factory}}
      broken = Chronicle::RaisingSink.new("broken")
      g = Chronicle::GraphProjection.empty
      g.add_sink(good, name: "candidate")
      g.add_sink(broken, name: "broken")

      3.times { |i| g.emit(SinkConformanceFixture.event((i + 1).to_u64, "evt_#{i + 1}")) }
      g.flush_sinks

      good.events.map(&.id).should eq(["evt_1", "evt_2", "evt_3"])
      g.sink_statuses["candidate"].delivered.should eq(3)
      g.sink_statuses["candidate"].errors.should eq(0)
      g.sink_statuses["broken"].errors.should eq(3)
    end

    it "replayed history is not redelivered to a newly attached sink" do
      sink = {{sink_factory}}
      g = Chronicle::GraphProjection.empty
      g.emit(SinkConformanceFixture.event(1_u64, "evt_1"))
      g.emit(SinkConformanceFixture.event(2_u64, "evt_2"))

      replayed = Chronicle::GraphProjection.replay(g.events)
      replayed.add_sink(sink, name: "test")
      replayed.flush_sinks

      sink.events.should be_empty
    end
  end
end
