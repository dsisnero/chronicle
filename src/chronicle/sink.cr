require "json"

# Sink surface for outbound observers of accepted events. Ported from
# activegraph activegraph/sinks/base.py, sinks/testing.py, sinks/jsonl.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed), adapted to the
# Sans-IO core: emit enqueues into a bounded FIFO and `flush_sinks` drains it
# (no worker threads).
module Chronicle
  enum OverflowPolicy
    DropNewest
    DropOldest
    FailSink
  end

  enum SinkState
    Running
    Closed
    Failed
  end

  struct DeliveryContext
    getter run_id : String
    getter sequence : UInt64
    getter mode : String

    def initialize(@run_id : String, @sequence : UInt64, @mode : String = "live")
    end
  end

  struct SinkStatus
    getter name : String
    getter run_id : String
    getter state : SinkState
    getter queue_capacity : Int32
    getter queue_depth : Int32
    getter enqueued : Int64
    getter delivered : Int64
    getter dropped : Int64
    getter errors : Int64

    def initialize(
      @name : String,
      @run_id : String,
      @state : SinkState,
      @queue_capacity : Int32,
      @queue_depth : Int32,
      @enqueued : Int64,
      @delivered : Int64,
      @dropped : Int64,
      @errors : Int64,
    )
    end
  end

  # Outbound observer of accepted runtime events. Every return is ignored and
  # every exception is isolated into sink status/metrics, never into execution.
  abstract class Sink
    def open : Nil
    end

    abstract def on_event(event : Event, context : DeliveryContext) : Nil

    def flush : Nil
    end

    def close : Nil
    end
  end

  # One isolated sink attachment: a bounded FIFO with an overflow policy.
  class SinkHandle
    getter sink : Sink
    getter name : String
    getter run_id : String
    getter queue_capacity : Int32
    getter overflow_policy : OverflowPolicy

    @queue : Deque(Event)
    @enqueued : Int64
    @delivered : Int64
    @dropped : Int64
    @errors : Int64
    @state : SinkState

    def initialize(
      @sink : Sink,
      @name : String,
      @run_id : String,
      @queue_capacity : Int32 = 1024,
      @overflow_policy : OverflowPolicy = OverflowPolicy::DropNewest,
    )
      @queue = Deque(Event).new
      @enqueued = 0_i64
      @delivered = 0_i64
      @dropped = 0_i64
      @errors = 0_i64
      @state = SinkState::Running
    end

    def offer(event : Event) : Nil
      return if @state.closed? || @state.failed?

      @enqueued += 1
      if @queue.size >= @queue_capacity
        case @overflow_policy
        in .drop_newest?
          @dropped += 1
        in .drop_oldest?
          @queue.shift
          @queue.push(event)
        in .fail_sink?
          @dropped += 1
          @state = SinkState::Failed
        end
      else
        @queue.push(event)
      end
    end

    def flush : Nil
      until @queue.empty?
        event = @queue.shift
        begin
          @sink.on_event(event, DeliveryContext.new(@run_id, event.sequence))
          @delivered += 1
        rescue
          @errors += 1
        end
      end
      @sink.flush
    rescue
      @errors += 1
    end

    def close : Nil
      @sink.close
      @state = SinkState::Closed
    end

    def status : SinkStatus
      SinkStatus.new(
        @name, @run_id, @state, @queue_capacity, @queue.size,
        @enqueued, @delivered, @dropped, @errors,
      )
    end
  end

  # Collects delivered events in memory.
  class TestingSink < Sink
    getter events : Array(Event) = [] of Event
    getter contexts : Array(DeliveryContext) = [] of DeliveryContext

    def initialize(@name : String = "testing")
    end

    def on_event(event : Event, context : DeliveryContext) : Nil
      events << event
      contexts << context
    end
  end

  # Writes accepted events as newline-delimited canonical JSON.
  class JSONLSink < Sink
    @io : IO

    def initialize(@name : String = "jsonl", @io : IO = STDOUT)
    end

    def on_event(event : Event, context : DeliveryContext) : Nil
      @io << event.canonical_json << '\n'
    end

    def flush : Nil
      @io.flush
    end
  end
end
