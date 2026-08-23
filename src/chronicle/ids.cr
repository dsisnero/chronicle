require "json"

# Per-graph monotonic ID generation. Ported from activegraph
# activegraph/core/ids.py (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).
#
# Objects share one global counter prefixed by type — task#1, task#2, claim#3,
# not claim#1; events, relations, patches, and frames each have their own
# evt_ / rel_ / patch_ / frame_ sequence. Replay does not call this: recorded
# events carry their ids, which keeps forked and reloaded runs aligned with
# their logs. `reseed_from_events` rebuilds counters after a replay.
# `run` mirrors upstream and returns a ULID from the wall clock + secure
# randomness; only routing is required to be deterministic in Chronicle.
module Chronicle
  class IDGen
    CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    @object_counter : Int32
    @event_counter : Int32
    @relation_counter : Int32
    @patch_counter : Int32
    @frame_counter : Int32

    def initialize
      @object_counter = 0
      @event_counter = 0
      @relation_counter = 0
      @patch_counter = 0
      @frame_counter = 0
    end

    def object(type : String) : String
      @object_counter += 1
      "#{type}##{@object_counter}"
    end

    def event : String
      @event_counter += 1
      "evt_%03d" % @event_counter
    end

    def relation : String
      @relation_counter += 1
      "rel_%03d" % @relation_counter
    end

    def patch : String
      @patch_counter += 1
      "patch_%03d" % @patch_counter
    end

    def frame : String
      @frame_counter += 1
      "frame_%03d" % @frame_counter
    end

    # 26-char Crockford base32 ULID: 48-bit millisecond timestamp prefix + 80-bit
    # random suffix. Not counter-based: runs live in storage and are looked up by
    # id, so cross-file collisions are the risk.
    def run : String
      ms = (Time.utc.to_unix_ms & ((1_i64 << 48) - 1)).to_u128
      bytes = Random::Secure.random_bytes(10)
      n = (ms << 80) | bytes.reduce(0_u128) { |acc, byte| (acc << 8) | byte }
      String.build do |io|
        26.times do
          io << CROCKFORD[n & 0x1F]
          n >>= 5
        end
      end
    end

    # The current counters as a hash, for the runtime.snapshot payload
    # (CONTRACT v1.5 #2) so a load from the snapshot can reseed past them.
    def snapshot_counters : Hash(String, Int32)
      {
        "object"   => @object_counter,
        "event"    => @event_counter,
        "relation" => @relation_counter,
        "patch"    => @patch_counter,
        "frame"    => @frame_counter,
      }
    end

    # Set counters from a snapshot's `id_counters` payload.
    def reseed_from_snapshot(counters : Hash(String, Int32)) : self
      @object_counter = Math.max(@object_counter, counters["object"]? || 0)
      @event_counter = Math.max(@event_counter, counters["event"]? || 0)
      @relation_counter = Math.max(@relation_counter, counters["relation"]? || 0)
      @patch_counter = Math.max(@patch_counter, counters["patch"]? || 0)
      @frame_counter = Math.max(@frame_counter, counters["frame"]? || 0)
      self
    end

    # Set counters past the highest id seen in `events` so subsequent
    # object()/event()/... continue monotonically from where the loaded log
    # ended. Forks call this too, which is why two forks at the same point
    # produce ids that diverge identically (fine: the ids live in different runs).
    def reseed_from_events(events : Array(Event)) : self
      max_obj = 0
      max_evt = 0
      max_rel = 0
      max_patch = 0
      events.each do |event|
        if n = suffix_num(event.id)
          max_evt = Math.max(max_evt, n)
        end
        counts = event_counter_maxes(event)
        max_obj = Math.max(max_obj, counts[:max_obj])
        max_rel = Math.max(max_rel, counts[:max_rel])
        max_patch = Math.max(max_patch, counts[:max_patch])
      end
      @object_counter = Math.max(@object_counter, max_obj)
      @event_counter = Math.max(@event_counter, max_evt)
      @relation_counter = Math.max(@relation_counter, max_rel)
      @patch_counter = Math.max(@patch_counter, max_patch)
      self
    end

    private def event_counter_maxes(event : Event) : NamedTuple(max_obj: Int32, max_rel: Int32, max_patch: Int32)
      payload = JSON.parse(event.payload).as_h
      case event.type
      when "object.created", "object.patched"
        {max_obj: or_zero(object_num(payload["id"]?.try(&.as_s))), max_rel: 0, max_patch: 0}
      when "relation.created"
        {max_obj: 0, max_rel: or_zero(suffix_num(payload["id"]?.try(&.as_s))), max_patch: 0}
      when "patch.proposed", "patch.applied"
        patch_id = if patch = payload["patch"]?
                     patch["id"]?.try(&.as_s)
                   end
        {max_obj: 0, max_rel: 0, max_patch: or_zero(suffix_num(patch_id))}
      when "patch.rejected"
        {max_obj: 0, max_rel: 0, max_patch: or_zero(suffix_num(payload["patch_id"]?.try(&.as_s)))}
      else
        {max_obj: 0, max_rel: 0, max_patch: 0}
      end
    end

    private def or_zero(n : Int32?) : Int32
      n || 0
    end

    private def suffix_num(s : String?) : Int32?
      return nil if s.nil?
      if m = s.match(/^[a-zA-Z]+_(\d+)$/)
        m[1].to_i
      end
    end

    private def object_num(s : String?) : Int32?
      return nil if s.nil?
      if m = s.match(/^[^#]+#(\d+)$/)
        m[1].to_i
      end
    end
  end
end
