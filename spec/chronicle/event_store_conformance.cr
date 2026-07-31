require "../spec_helper"

# Reusable EventStore contract suite. Ported from activegraph
# activegraph/store/conformance.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
# A backend gets full coverage by invoking `EventStoreConformance.define_tests`
# with an expression that yields a fresh, empty store inside each test.

module EventStoreConformanceFixture
  extend self

  def event(eid : String, type : String = "object.created", payload : String = %({"k":"v"})) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: eid,
      type: type, actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: payload,
    )
  end
end

module EventStoreConformance
  # `store_factory` is an expression producing a fresh, empty EventStore.
  # `cleanup` (optional) is run in an ensure block after each test.
  macro define_tests(store_factory, cleanup = nil)
    it "appends then iterates in order" do
      store = {{store_factory}}
      begin
        (0...5).each { |i| store.append(EventStoreConformanceFixture.event("evt_#{i}")) }
        store.iter_events.map(&.id).should eq(["evt_0", "evt_1", "evt_2", "evt_3", "evt_4"])
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "reports count" do
      store = {{store_factory}}
      begin
        store.count.should eq(0_i64)
        store.append(EventStoreConformanceFixture.event("evt_a"))
        store.append(EventStoreConformanceFixture.event("evt_b"))
        store.count.should eq(2_i64)
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "gets known and unknown events" do
      store = {{store_factory}}
      begin
        store.append(EventStoreConformanceFixture.event("evt_known"))
        store.get_event("evt_known").should_not be_nil
        store.get_event("evt_missing").should be_nil
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "iterates after a boundary, excluding it" do
      store = {{store_factory}}
      begin
        (0...4).each { |i| store.append(EventStoreConformanceFixture.event("evt_#{i}")) }
        store.iter_events(after: "evt_1").map(&.id).should eq(["evt_2", "evt_3"])
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "iterates before a boundary, including it" do
      store = {{store_factory}}
      begin
        (0...4).each { |i| store.append(EventStoreConformanceFixture.event("evt_#{i}")) }
        store.iter_events(before: "evt_2").map(&.id).should eq(["evt_0", "evt_1", "evt_2"])
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "truncates after a boundary, dropping the tail" do
      store = {{store_factory}}
      begin
        (0...5).each { |i| store.append(EventStoreConformanceFixture.event("evt_#{i}")) }
        store.truncate_after("evt_2")
        store.iter_events.map(&.id).should eq(["evt_0", "evt_1", "evt_2"])
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "round-trips payload structure" do
      store = {{store_factory}}
      begin
        payload = %({"nested":{"k":[1,2,{"a":"b"}]},"unicode":"café — 🚀","empty":[],"null_in_value":null})
        store.append(EventStoreConformanceFixture.event("evt_payload", payload: payload))
        got = store.get_event("evt_payload").not_nil!
        got.payload.should eq(payload)
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "rejects a duplicate id in the same run" do
      store = {{store_factory}}
      begin
        store.append(EventStoreConformanceFixture.event("evt_dup"))
        expect_raises(Chronicle::DuplicateEventError) do
          store.append(EventStoreConformanceFixture.event("evt_dup"))
        end
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end

    it "closes idempotently" do
      store = {{store_factory}}
      begin
        store.append(EventStoreConformanceFixture.event("evt_a"))
        store.close
        store.close
      {% if cleanup %}
      ensure
        {{cleanup}}
      {% end %}
      end
    end
  end
end
