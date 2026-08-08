require "json"

module Chronicle
  # Context-read tracing for behavior executions (CONTRACT v1.10 #1).
  #
  # When a runtime is constructed with `trace_context_reads: true`, every
  # behavior execution gets a ReadRecorder threaded through its read surface
  # (`ctx.view.objects`, plus LLM-prompt view objects). When the execution
  # commits, the runtime emits ONE batched `context.read` event carrying the
  # ordered, deduplicated list of object ids the execution read.
  #
  # Determinism: the read set derives purely from the behavior's actual
  # accessor calls in first-read order — no timestamps, no set iteration —
  # so a replayed execution reproduces its `context.read` byte for byte.
  module ContextRead
    extend self

    # CONTRACT v1.10 #1: `object_ids` on a context.read payload is bounded.
    # `count` stays exact past the cap; `truncated: true` marks the cut.
    CONTEXT_READ_ID_CAP = 200

    # Ordered, deduplicated object-id read set for ONE behavior execution.
    # First read wins the position; later reads of the same id are no-ops.
    # Plain list + set — insertion order is the only order, so the recorded
    # sequence is replay-stable by construction.
    class ReadRecorder
      @seen = Set(String).new
      @order = [] of String

      def record(object_id : String) : Nil
        return if @seen.includes?(object_id)

        @seen << object_id
        @order << object_id
      end

      def record_objects(objects : Array(GraphObject)) : Nil
        objects.each do |obj|
          record(obj.id)
        end
      end

      def object_ids : Array(String)
        @order.dup
      end

      def size : Int32
        @order.size
      end

      def empty? : Bool
        @order.empty?
      end
    end

    # A View that records object reads. Substituted for the plain view as
    # `ctx.view` when the runtime has `trace_context_reads: true`. Only
    # `objects` records — the ids of exactly the objects each call returns
    # (post-filter), so the trace reflects what the behavior actually saw.
    # `relations` and `events` are inherited untraced: they read relations
    # and events, not objects.
    class TracedView
      getter view : View

      def initialize(@view : View, @recorder : ReadRecorder)
      end

      def objects(type : String? = nil) : Array(GraphObject)
        result = if type
                   @view.objects.select { |obj| obj.type == type }
                 else
                   @view.objects
                 end
        @recorder.record_objects(result)
        result
      end

      def relations : Array(GraphRelation)
        @view.relations
      end

      def events : Array(Event)
        @view.events
      end
    end

    # Build the `context.read` payload for one committed execution.
    # `execution_event_id` is the id of the execution's `behavior.started`
    # event — the frame reference that ties the read set to one invocation.
    # `object_ids` is capped at CONTEXT_READ_ID_CAP; `count` is always the
    # exact deduplicated total, and `truncated` appears (as true) only when
    # ids were dropped.
    def context_read_payload(
      *,
      behavior_name : String,
      event_id : String,
      execution_event_id : String,
      recorder : ReadRecorder,
    ) : Hash(String, JSON::Any)
      ids = recorder.object_ids
      payload = {
        "behavior"           => JSON::Any.new(behavior_name),
        "event_id"           => JSON::Any.new(event_id),
        "execution_event_id" => JSON::Any.new(execution_event_id),
        "object_ids"         => JSON::Any.new(ids.first(CONTEXT_READ_ID_CAP).map { |id| JSON::Any.new(id) }),
        "count"              => JSON::Any.new(ids.size),
      }
      if ids.size > CONTEXT_READ_ID_CAP
        payload["truncated"] = JSON::Any.new(true)
      end
      payload
    end
  end
end
