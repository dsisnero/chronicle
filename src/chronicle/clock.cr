module Chronicle
  # Abstract clock interface. Behaviors get time only through this interface
  # so deterministic runs can swap in FrozenClock or TickingClock and replay
  # never depends on the machine clock.
  abstract class Clock
    abstract def now : Time
  end

  # Real wall-clock UTC. The default time source for event timestamps.
  class WallClock < Clock
    def now : Time
      Time.utc
    end
  end

  # Always returns the same timestamp. For tests and snapshots.
  # Every `now` call yields the same value, so an event log written under a
  # FrozenClock is byte-for-byte reproducible.
  class FrozenClock < Clock
    DEFAULT_TIME = Time.utc(2026, 5, 15, 10, 32, 1)

    def initialize(@t : Time = DEFAULT_TIME)
    end

    def now : Time
      @t
    end
  end

  # Monotonically advances by step_seconds on every call.
  # For tests that care about ordering but don't want wall-clock noise.
  class TickingClock < Clock
    def initialize(@t : Time = Time.utc(2026, 5, 15, 10, 32, 1), @step_seconds : Int32 = 1)
    end

    def now : Time
      t = @t
      @t = @t + @step_seconds.seconds
      t
    end
  end
end
