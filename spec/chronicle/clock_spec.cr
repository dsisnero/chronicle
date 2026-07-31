require "../spec_helper"

describe Chronicle::Clock do
  it "WallClock returns the current UTC time" do
    clock = Chronicle::WallClock.new
    t = clock.now
    t.should be_a(Time)
    t.utc?.should be_true
  end

  it "FrozenClock always returns the same timestamp" do
    frozen = Time.utc(2026, 7, 25, 12, 0, 0)
    clock = Chronicle::FrozenClock.new(frozen)
    clock.now.should eq(frozen)
    clock.now.should eq(frozen)
    clock.now.should eq(frozen)
  end

  it "FrozenClock defaults to a known timestamp" do
    clock = Chronicle::FrozenClock.new
    clock.now.should eq(Chronicle::FrozenClock::DEFAULT_TIME)
  end

  it "TickingClock advances monotonically" do
    start = Time.utc(2026, 7, 25, 12, 0, 0)
    clock = Chronicle::TickingClock.new(start, step_seconds: 5)

    t1 = clock.now
    t2 = clock.now
    t3 = clock.now

    t1.should eq(start)
    t2.should eq(start + 5.seconds)
    t3.should eq(start + 10.seconds)
  end

  it "TickingClock defaults to 1-second steps" do
    start = Time.utc(2026, 7, 25, 12, 0, 0)
    clock = Chronicle::TickingClock.new(start)

    t1 = clock.now
    t2 = clock.now

    t2.should eq(t1 + 1.second)
  end
end
