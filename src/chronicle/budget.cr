module Chronicle
  # Hard limits on a run. When any limit is hit the runtime stops gracefully
  # and emits runtime.budget_exhausted. Ported from
  # activegraph.runtime.budget (CONTRACT v0.6 #9).
  #
  # Construct with a dict over the KNOWN_LIMITS dimensions; any omitted
  # dimension is unlimited. `max_cost_usd` accumulates as Float64 (upstream
  # uses Decimal; the divergence is documented — per-call sub-cent costs add
  # cleanly for realistic magnitudes) and is also mirrored as a String so
  # consumers keep a stable serialized form.
  struct Budget
    KNOWN_LIMITS = [
      "max_events", "max_behavior_calls", "max_llm_calls", "max_tool_calls",
      "max_patches", "max_depth", "max_seconds", "max_cost_usd",
    ]

    getter limits : Hash(String, Float64)
    getter used : Hash(String, Float64)
    getter cost_limit : String?

    @cost_used : Float64 = 0.0
    @start : Time::Instant?
    @exhausted_by : String?

    def initialize(limits : Hash(String, Float64 | String)? = nil)
      @limits = {} of String => Float64
      @cost_limit = nil
      KNOWN_LIMITS.each do |key|
        raw = limits.try(&.[key]?)
        if key == "max_cost_usd"
          if raw
            value = raw.to_f
            @cost_limit = raw.to_s
            @limits[key] = value
          else
            @limits[key] = Float64::INFINITY
          end
        else
          @limits[key] = raw ? raw.to_f : Float64::INFINITY
        end
      end
      @used = {} of String => Float64
      KNOWN_LIMITS.each { |key| @used[key] = 0.0 }
    end

    # Event-count convenience constructor (the pre-port `Runtime::Budget`
    # shape). Sets only the `max_events` dimension.
    def initialize(max_events : Int64)
      initialize(limits: {"max_events" => max_events.to_f})
    end

    # Start budget accounting, optionally without ambient clock I/O. Strict
    # replay passes `read_wall_clock: false` and stops at the recorded
    # accepted-event sequence instead of re-racing monotonic time.
    def start(*, read_wall_clock : Bool = true) : Nil
      @start = read_wall_clock ? Time.instant : Time::Instant.new(0, 0)
    end

    def consume(key : String, amount : Float64 = 1.0) : Nil
      @used[key] = @used.fetch(key, 0.0) + amount
    end

    def exhausted_by : String?
      @exhausted_by
    end

    # Whether every enabled limit still has capacity.
    def remaining(*, check_wall_clock : Bool = true) : Bool
      start = @start
      cost_ceiling = @cost_limit
      @limits.each do |key, limit|
        case key
        when "max_seconds"
          next unless check_wall_clock
          next if start.nil?
          if (Time.instant - start).total_seconds >= limit
            @exhausted_by = key
            return false
          end
        when "max_cost_usd"
          if cost_ceiling && @cost_used >= cost_ceiling.to_f
            @exhausted_by = key
            return false
          end
        else
          if @used.fetch(key, 0.0) >= limit
            @exhausted_by = key
            return false
          end
        end
      end
      true
    end

    # Set the authoritative exhaustion reason for recorded replay.
    def mark_exhausted(key : String) : Nil
      @exhausted_by = key
    end

    def has_cost_limit : Bool
      !@cost_limit.nil?
    end

    def add_cost(amount : String | Float64) : Nil
      value = amount.to_f
      @cost_used += value
      @used["max_cost_usd"] = @cost_used
    end

    def cost_used : String
      @cost_used.to_s
    end

    # Would `prospective_cost` push us past the ceiling? Returns True if it's
    # safe to spend, False if it would exceed.
    def cost_remaining(prospective_cost : String | Float64) : Bool
      cost_ceiling = @cost_limit
      return true if cost_ceiling.nil?

      @cost_used + prospective_cost.to_f <= cost_ceiling.to_f
    end

    def cost_remaining_amount : String?
      cost_ceiling = @cost_limit
      return nil if cost_ceiling.nil?

      remaining = cost_ceiling.to_f - @cost_used
      remaining > 0 ? remaining.to_s : "0"
    end

    def snapshot : BudgetSnapshot
      used_json = {} of String => Float64
      @used.each { |key, value| used_json[key] = value }
      limits_json = {} of String => Float64?
      @limits.each do |key, value|
        limits_json[key] = value == Float64::INFINITY ? nil : value
      end
      BudgetSnapshot.new(
        used: used_json,
        limits: limits_json,
        cost_used_usd: @cost_used.to_s,
        cost_limit_usd: @cost_limit,
        exhausted_by: @exhausted_by,
      )
    end
  end
end
