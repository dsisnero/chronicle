# Runtime introspection — `RuntimeStatus` and friends. CONTRACT v0.8 #11.
# Ported from activegraph.observability.status: a frozen snapshot of the
# runtime returned by `Runtime#status`. Cheap to call, safe from anywhere,
# immutable value objects. There is no `last_error` field — errors are events;
# filter `recent_events` for `behavior.failed`.

module Chronicle
  enum RuntimeState
    Idle
    Running
    Stopped
    Exhausted
  end

  # Budget usage/limits at snapshot time.
  struct BudgetSnapshot
    getter used : Hash(String, Float64)
    getter limits : Hash(String, Float64?)
    getter cost_used_usd : String
    getter cost_limit_usd : String?
    getter exhausted_by : String?

    def initialize(
      @used : Hash(String, Float64),
      @limits : Hash(String, Float64?),
      @cost_used_usd : String,
      @cost_limit_usd : String?,
      @exhausted_by : String?,
    )
    end
  end

  # The active frame at snapshot time.
  struct FrameSnapshot
    getter id : String?
    getter name : String?

    def initialize(@id : String?, @name : String?)
    end
  end

  # One registered behavior's subscription surface.
  struct BehaviorInfo
    getter name : String
    getter kind : String # "function" | "relation" | "llm"
    getter subscribed_to : Array(String)
    getter pattern : String?
    getter activate_after : Int32?

    def initialize(
      @name : String,
      @kind : String,
      @subscribed_to : Array(String),
      @pattern : String? = nil,
      @activate_after : Int32? = nil,
    )
    end
  end

  # One recent event's summary (id/type/actor/timestamp).
  struct EventSummary
    getter id : String
    getter type : String
    getter actor : String?
    getter timestamp : String

    def initialize(
      @id : String,
      @type : String,
      @actor : String?,
      @timestamp : String,
    )
    end
  end

  # Point-in-time snapshot of a runtime for inspection surfaces. A read-only
  # value object produced by `Runtime#status`. Ported from upstream's frozen
  # `RuntimeStatus` dataclass.
  struct RuntimeStatus
    getter run_id : String
    getter state : RuntimeState
    getter queue_depth : Int32
    getter events_processed : Int64
    getter budget : BudgetSnapshot
    getter frame : FrameSnapshot?
    getter registered_behaviors : Array(BehaviorInfo)
    getter recent_events : Array(EventSummary)

    def initialize(
      @run_id : String,
      @state : RuntimeState,
      @queue_depth : Int32,
      @events_processed : Int64,
      @budget : BudgetSnapshot,
      @frame : FrameSnapshot?,
      @registered_behaviors : Array(BehaviorInfo),
      @recent_events : Array(EventSummary),
    )
    end

    def copy_with(
      run_id : String = @run_id,
      state : RuntimeState = @state,
      queue_depth : Int32 = @queue_depth,
      events_processed : Int64 = @events_processed,
      budget : BudgetSnapshot = @budget,
      frame : FrameSnapshot? = @frame,
      registered_behaviors : Array(BehaviorInfo) = @registered_behaviors,
      recent_events : Array(EventSummary) = @recent_events,
    ) : RuntimeStatus
      RuntimeStatus.new(
        run_id: run_id, state: state, queue_depth: queue_depth,
        events_processed: events_processed, budget: budget, frame: frame,
        registered_behaviors: registered_behaviors, recent_events: recent_events,
      )
    end

    # JSON-serializable form, matching upstream `status_to_dict` field names.
    def to_h : Hash(String, JSON::Any)
      cost_limit = @budget.cost_limit_usd
      exhausted_by = @budget.exhausted_by
      frame_snapshot = @frame
      frame_id = frame_snapshot.try(&.id)
      frame_name = frame_snapshot.try(&.name)
      behaviors = @registered_behaviors.map do |behavior|
        pattern = behavior.pattern
        activate_after = behavior.activate_after
        JSON::Any.new({
          "name"           => JSON::Any.new(behavior.name),
          "kind"           => JSON::Any.new(behavior.kind),
          "subscribed_to"  => JSON::Any.new(behavior.subscribed_to.map { |event_type| JSON::Any.new(event_type) }),
          "pattern"        => pattern.nil? ? JSON::Any.new(nil) : JSON::Any.new(pattern),
          "activate_after" => activate_after.nil? ? JSON::Any.new(nil) : JSON::Any.new(activate_after),
        })
      end
      recent = @recent_events.map do |event|
        actor = event.actor
        JSON::Any.new({
          "id"        => JSON::Any.new(event.id),
          "type"      => JSON::Any.new(event.type),
          "actor"     => actor.nil? ? JSON::Any.new(nil) : JSON::Any.new(actor),
          "timestamp" => JSON::Any.new(event.timestamp),
        })
      end
      {
        "run_id"           => JSON::Any.new(@run_id),
        "state"            => JSON::Any.new(@state.to_s.downcase),
        "queue_depth"      => JSON::Any.new(@queue_depth),
        "events_processed" => JSON::Any.new(@events_processed),
        "budget"           => JSON::Any.new({
          "used"           => JSON::Any.new(@budget.used.transform_values { |value| JSON::Any.new(value) }),
          "limits"         => JSON::Any.new(@budget.limits.transform_values { |value| value.nil? ? JSON::Any.new(nil) : JSON::Any.new(value) }),
          "cost_used_usd"  => JSON::Any.new(@budget.cost_used_usd),
          "cost_limit_usd" => cost_limit.nil? ? JSON::Any.new(nil) : JSON::Any.new(cost_limit),
          "exhausted_by"   => exhausted_by.nil? ? JSON::Any.new(nil) : JSON::Any.new(exhausted_by),
        }),
        "frame" => frame_snapshot.nil? ? JSON::Any.new(nil) : JSON::Any.new({
          "id"   => frame_id.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_id),
          "name" => frame_name.nil? ? JSON::Any.new(nil) : JSON::Any.new(frame_name),
        }),
        "registered_behaviors" => JSON::Any.new(behaviors),
        "recent_events"        => JSON::Any.new(recent),
      }
    end
  end
end
