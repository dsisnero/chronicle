require "../spec_helper"

# IDGen specs. Ported from activegraph tests/test_ids.py plus characterization
# of reseed_from_events from activegraph/core/ids.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

module IDGenSpecHelper
  extend self

  def event(seq : UInt64, id : String, type : String, payload : String) : Clarity::Event
    Clarity::Event.new(
      schema_version: 1_u16, sequence: seq, id: id,
      type: type, actor: "test", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload,
    )
  end
end

describe Clarity::IDGen do
  it "produces global monotonic object ids prefixed by type" do
    ids = Clarity::IDGen.new
    ids.object("task").should eq("task#1")
    ids.object("task").should eq("task#2")
    ids.object("claim").should eq("claim#3")
  end

  it "zero-pads event ids" do
    ids = Clarity::IDGen.new
    ids.event.should eq("evt_001")
    ids.event.should eq("evt_002")
  end

  it "keeps relation, patch, and frame namespaces separate" do
    ids = Clarity::IDGen.new
    ids.relation.should eq("rel_001")
    ids.patch.should eq("patch_001")
    ids.frame.should eq("frame_001")
  end

  it "generates 26-char Crockford ULIDs for runs" do
    ids = Clarity::IDGen.new
    a = ids.run
    b = ids.run
    a.size.should eq(26)
    a.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)
    a.should_not eq(b)
  end

  it "reseeds counters past the highest ids seen in events" do
    ids = Clarity::IDGen.new
    events = [
      IDGenSpecHelper.event(1_u64, "evt_000042", "object.created", %({"id":"claim#5","type":"claim","data":{}})),
      IDGenSpecHelper.event(2_u64, "evt_000043", "relation.created", %({"id":"rel_000007","type":"cites","from_id":"claim#5","to_id":"doc#1"})),
      IDGenSpecHelper.event(3_u64, "evt_000044", "patch.proposed", %({"patch":{"id":"patch_000002","target":"claim#5"}})),
    ]
    ids.reseed_from_events(events)
    ids.object("task").should eq("task#6")
    ids.event.should eq("evt_045")
    ids.relation.should eq("rel_008")
    ids.patch.should eq("patch_003")
  end
end
