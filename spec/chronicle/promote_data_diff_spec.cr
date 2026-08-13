require "../spec_helper"

private def data_hash(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

describe Chronicle::RuntimeReason do
  it "renders per-field {old, new} for changed fields (upstream _promote_data_diff)" do
    diff = Chronicle::RuntimeReason.promote_data_diff(
      data_hash(%({"name":"a","count":1,"same":"x"})),
      data_hash(%({"name":"b","count":2,"same":"x"})),
    )
    diff.keys.should eq(["count", "name"])
    diff["name"].should eq(data_hash(%({"old":"a","new":"b"})))
    diff["count"].should eq(data_hash(%({"old":1,"new":2})))
  end

  it "sorts keys by name" do
    diff = Chronicle::RuntimeReason.promote_data_diff(
      data_hash(%({"z":1,"a":2})),
      data_hash(%({"z":3,"a":4})),
    )
    diff.keys.should eq(["a", "z"])
  end

  it "renders dropped fields as new=null" do
    diff = Chronicle::RuntimeReason.promote_data_diff(
      data_hash(%({"drop":"gone","keep":1})),
      data_hash(%({"keep":1})),
    )
    diff.keys.should eq(["drop"])
    diff["drop"]["old"].as_s.should eq("gone")
    diff["drop"]["new"].raw.should be_nil
  end

  it "renders added fields as old=null" do
    diff = Chronicle::RuntimeReason.promote_data_diff(
      data_hash(%({"keep":1})),
      data_hash(%({"keep":1,"add":2})),
    )
    diff.keys.should eq(["add"])
    diff["add"]["old"].raw.should be_nil
    diff["add"]["new"].as_i.should eq(2)
  end

  it "omits fields that are numerically equal (3 == 3.0)" do
    diff = Chronicle::RuntimeReason.promote_data_diff(
      data_hash(%({"n":3})),
      data_hash(%({"n":3.0})),
    )
    diff.should be_empty
  end

  it "is empty for identical data" do
    diff = Chronicle::RuntimeReason.promote_data_diff(
      data_hash(%({"a":1,"b":[1,2]})),
      data_hash(%({"a":1,"b":[1,2]})),
    )
    diff.should be_empty
  end
end
