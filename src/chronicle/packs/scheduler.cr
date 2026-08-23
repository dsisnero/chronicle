# Event-count scheduler for `activate_after`. Ported from
# activegraph.runtime.scheduler (revision
# 148e12c2969f18fa12a1a3c2e75f3affd9aa0616). CONTRACT v0.7 #13.
#
# `activate_after` is event-count only, never wall-clock. When a triggering
# event matches a behavior with `activate_after=N`, the runtime emits
# `behavior.scheduled` and pushes a delayed entry that fires N events later.
# After each dispatched event the runtime pops whatever is due and (re)checks
# the `where=` clause before invoking; a where that no longer holds is skipped
# silently (no extra event).
module Chronicle
  module Packs
    # `parse_activate_after` was passed an unparseable or out-of-range value.
    # Raised during pack construction, mirroring activegraph's
    # InvalidActivateAfter (a RegistrationError/ValueError).
    class InvalidActivateAfter < PackError
      getter spec : (Int32 | String | Bool)
      getter kind : String

      def initialize(@spec : (Int32 | String | Bool), @kind : String)
        super("activate_after=#{@spec.inspect} is invalid (#{@kind}); scheduler requires an integer event count (int or 'N events')")
      end
    end

    # Parse `activate_after=` into an integer event count. Accepts an int
    # (>= 1) or the strings "N", "N event", "N events". Rejects bool, zero or
    # negative, wall-clock units (seconds/minutes/...), and unparseable
    # strings. Mirrors activegraph.runtime.scheduler.parse_activate_after.
    WALL_CLOCK_WORDS = %w[second seconds ms millisecond milliseconds minute minutes min mins hour hours day days week weeks]

    def self.parse_activate_after(spec : (Int32 | String | Bool)) : Int32
      n =
        case spec
        in Bool
          raise InvalidActivateAfter.new(spec, "bool not int")
        in Int32
          spec
        in String
          s = spec.strip.downcase
          WALL_CLOCK_WORDS.each do |word|
            if s.split.includes?(word)
              raise InvalidActivateAfter.new(spec, "wall-clock unit")
            end
          end
          m = s.match(/\A\s*(\d+)\s*(events?)?\s*\z/)
          raise InvalidActivateAfter.new(spec, "unparseable string") unless m
          m[1].to_i
        end
      if n < 1
        raise InvalidActivateAfter.new(spec, "must be >= 1")
      end
      n
    end

    # A pending `activate_after` invocation.
    record ScheduledEntry,
      behavior_name : String,
      triggering_event_id : String,
      fire_at_sequence : UInt64,
      scheduled_event_id : String

    # The runtime's delayed queue. FIFO within a single fire tick.
    class DelayedQueue
      getter entries : Array(ScheduledEntry) = Array(ScheduledEntry).new

      def push(entry : ScheduledEntry) : Nil
        @entries << entry
      end

      def pop_due(current_sequence : UInt64) : Array(ScheduledEntry)
        due = [] of ScheduledEntry
        kept = [] of ScheduledEntry
        @entries.each do |entry|
          if entry.fire_at_sequence <= current_sequence
            due << entry
          else
            kept << entry
          end
        end
        @entries = kept
        due
      end

      def empty? : Bool
        @entries.empty?
      end
    end
  end
end
