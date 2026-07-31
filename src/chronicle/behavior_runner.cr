module Chronicle
  enum BehaviorStatus
    Completed
    Failed
    Suppressed
  end

  struct BehaviorRegistration
    getter id : String
    getter priority : Int32
    getter event_type : String
    getter handler : Proc(Event, GraphProjection, Array(EffectRequest))
    getter predicate : Proc(GraphProjection, Bool)?

    def initialize(
      @id : String,
      @priority : Int32,
      @event_type : String,
      @handler : Proc(Event, GraphProjection, Array(EffectRequest)),
      @predicate : Proc(GraphProjection, Bool)? = nil,
    )
    end

    def matches?(event : Event, graph : GraphProjection) : Bool
      return false unless event.type == @event_type
      return true unless predicate = @predicate

      predicate.call(graph)
    end
  end

  struct BehaviorLifecycle
    getter behavior_id : String
    getter trigger_event_id : String
    getter status : BehaviorStatus

    def initialize(@behavior_id : String, @trigger_event_id : String, @status : BehaviorStatus)
    end
  end

  struct RunnerLimits
    getter max_fan_out : Int32
    getter max_pending_effects : Int32

    def initialize(@max_fan_out : Int32 = 32, @max_pending_effects : Int32 = 256)
    end
  end

  struct RunnerResult
    getter lifecycle : Array(BehaviorLifecycle)
    getter effects : Array(EffectRequest)

    def initialize(@lifecycle : Array(BehaviorLifecycle), @effects : Array(EffectRequest))
    end
  end

  # Deterministically schedules matching behaviors without executing effects.
  class BehaviorRunner
    @registrations : Array(BehaviorRegistration)
    @limits : RunnerLimits

    def initialize(@registrations : Array(BehaviorRegistration), @limits = RunnerLimits.new)
    end

    def run(events : Array(Event), graph : GraphProjection) : RunnerResult
      scheduled = [] of {Event, BehaviorRegistration}
      events.each do |event|
        @registrations.each do |registration|
          scheduled << {event, registration} if registration.matches?(event, graph)
        end
      end
      scheduled.sort_by! { |entry| {entry[0].sequence, entry[1].priority, entry[1].id} }

      lifecycle = [] of BehaviorLifecycle
      effects = [] of EffectRequest
      scheduled.each do |event, registration|
        begin
          emitted = registration.handler.call(event, graph)
          if emitted.size > @limits.max_fan_out || effects.size + emitted.size > @limits.max_pending_effects
            lifecycle << BehaviorLifecycle.new(registration.id, event.id, BehaviorStatus::Suppressed)
            next
          end

          effects.concat(emitted)
          lifecycle << BehaviorLifecycle.new(registration.id, event.id, BehaviorStatus::Completed)
        rescue
          lifecycle << BehaviorLifecycle.new(registration.id, event.id, BehaviorStatus::Failed)
        end
      end

      RunnerResult.new(lifecycle, effects)
    end
  end
end
