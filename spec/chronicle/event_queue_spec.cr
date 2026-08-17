require "../spec_helper"

# EventQueue — the single in-process FIFO queue upstream dispatch drains
# (runtime/queue.py, CONTRACT #10: no priority, no async). Chronicle's own
# dispatch drains directly from the event store, so this is a parity shape:
# push / pop / size / empty? with FIFO ordering, used by tests and tools
# rather than the dispatch path.

describe Chronicle::EventQueue do
  it "pops events in FIFO order" do
    queue = Chronicle::EventQueue.new
    a = event("a")
    b = event("b")
    c = event("c")
    queue.push(a)
    queue.push(b)
    queue.push(c)

    queue.size.should eq(3)
    queue.empty?.should be_false
    queue.pop.should eq(a)
    queue.pop.should eq(b)
    queue.pop.should eq(c)
    queue.empty?.should be_true
  end

  it "returns nil from pop when empty" do
    queue = Chronicle::EventQueue.new
    queue.empty?.should be_true
    queue.pop.should be_nil
  end

  it "interleaves push and pop correctly" do
    queue = Chronicle::EventQueue.new
    queue.push(event("a"))
    queue.pop.should_not be_nil
    queue.push(event("b"))
    queue.push(event("c"))
    queue.pop.try(&.id).should eq("b")
    queue.pop.try(&.id).should eq("c")
    queue.pop.should be_nil
  end
end

private def event(id : String) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16,
    sequence: 1_u64,
    id: id,
    type: "tick",
    actor: "test",
    caused_by: nil,
    timestamp: Time.utc,
    payload: %({"i":1}),
  )
end
