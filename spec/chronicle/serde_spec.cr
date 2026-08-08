require "../spec_helper"

private def serde_event(
  id : String = "evt_000001",
  type : String = "chat.message",
  actor : String = "user",
  caused_by : String? = nil,
  frame_id : String? = nil,
  timestamp : Time = Time.utc(2026, 7, 24, 12, 0, 0),
  payload : String = %({"message":"hi"}),
  sequence : UInt64 = 1_u64,
) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16,
    sequence: sequence,
    id: id,
    type: type,
    actor: actor,
    caused_by: caused_by,
    frame_id: frame_id,
    timestamp: timestamp,
    payload: payload,
  )
end

describe Chronicle::Serde do
  describe "#encode_payload" do
    it "round-trips JSON primitives (test_primitive_types_round_trip)" do
      payload = JSON.parse(%({"s":"hi","i":1,"f":1.5,"b":true,"n":null,"l":[1,2]}))
      Chronicle::Serde.decode_payload(Chronicle::Serde.encode_payload(payload)).should eq(payload)
    end

    it "round-trips nested dicts and unicode (test_nested_dicts_and_unicode)" do
      payload = JSON.parse(%({"meta":{"name":"héllo 漢字 🚀","deep":{"k":[null,true]}}}))
      Chronicle::Serde.decode_payload(Chronicle::Serde.encode_payload(payload)).should eq(payload)
    end

    it "encodes a payload to canonical JSON without reformatting floats" do
      Chronicle::Serde.encode_payload(JSON.parse(%({"f":1.0,"i":1}))).should eq(%({"f":1.0,"i":1}))
    end
  end

  describe "#decode_payload" do
    it "decodes a valid JSON payload" do
      Chronicle::Serde.decode_payload(%({"k":"v"})).should eq(JSON.parse(%({"k":"v"})))
    end

    it "raises CorruptedEventPayloadError on corrupt JSON with a preview" do
      error = expect_raises(Chronicle::CorruptedEventPayloadError) do
        Chronicle::Serde.decode_payload("{oops")
      end
      error.message.not_nil!.should contain("decode")
    end

    it "truncates long payload previews" do
      long = "{\"a\":" + ("x" * 200) + "}"
      error = expect_raises(Chronicle::CorruptedEventPayloadError) do
        Chronicle::Serde.decode_payload(long)
      end
      error.message.not_nil!.should contain("...")
    end
  end

  describe "#validate_event" do
    it "accepts an event with a JSON-serializable payload (test_validate_event_accepts_good_payload)" do
      event = serde_event(payload: %({"k":"v"}))
      Chronicle::Serde.validate_event(event)
    end
  end

  describe "#encode_event / #decode_event" do
    it "round-trips the full envelope including frame_id and caused_by" do
      event = serde_event(
        id: "evt_000042",
        type: "goal.created",
        actor: "runtime",
        caused_by: "evt_000001",
        frame_id: "frame_abc",
        timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
        payload: %({"goal":"ship routing"}),
        sequence: 42_u64,
      )
      row = Chronicle::Serde.encode_event(event)
      restored = Chronicle::Serde.decode_event(row)

      restored.canonical_json.should eq(event.canonical_json)
      restored.payload.should eq(event.payload)
      restored.frame_id.should eq("frame_abc")
      restored.caused_by.should eq("evt_000001")
      restored.sequence.should eq(42_u64)
      restored.schema_version.should eq(1_u16)
    end

    it "serializes the row through JSON::Serializable with a raw payload string" do
      event = serde_event(payload: %({"message":"hi"}))
      row = Chronicle::Serde.encode_event(event)
      row.to_json.should contain(%("payload":{"message":"hi"}))
      row.to_json.should contain(%("id":"evt_000001"))
    end

    it "keeps the payload byte-exact through the row (never re-parses it)" do
      payload = %({"order":1.0,"text":"héllo 漢字 🚀","nested":{"a":[1,2,3]}})
      event = serde_event(payload: payload)
      restored = Chronicle::Serde.decode_event(Chronicle::Serde.encode_event(event))
      restored.payload.should eq(payload)
    end
  end

  describe "error taxonomy" do
    it "NonSerializableEventError is a StorageError and a DomainError" do
      error = Chronicle::NonSerializableEventError.new("nope")
      error.is_a?(Chronicle::StorageError).should be_true
      error.is_a?(Chronicle::DomainError).should be_true
      error.is_a?(ArgumentError).should be_true
    end

    it "CorruptedEventPayloadError is a StorageError and a DomainError" do
      error = Chronicle::CorruptedEventPayloadError.new("corrupt")
      error.is_a?(Chronicle::StorageError).should be_true
      error.is_a?(Chronicle::DomainError).should be_true
      error.is_a?(ArgumentError).should be_true
    end
  end

  describe "GraphProjection emit gate (CONTRACT v0.5 #4)" do
    it "validates an event against the serde gate before projecting when a store is attached" do
      store = Chronicle::MemoryEventStore.new
      projection = Chronicle::GraphProjection.new(store: Chronicle::InMemoryGraphStore.new)
      projection.attach_store(store)

      event = serde_event(payload: %({"goal":"hello"}))
      projection.emit(event)

      store.count.should eq(1_i64)
      projection.events.map(&.id).should eq(["evt_000001"])
    end
  end
end
