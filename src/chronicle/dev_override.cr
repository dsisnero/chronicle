module Chronicle
  # Run-local, log-backed developer override receipts (CONTRACT v1.8 #13–#15).
  # Ported from activegraph.runtime.dev_override.

  # One accepted `dev.override` receipt scoped to a run and gate. The receipt
  # is evidence a local operator recorded an exact bypass intent; it grants
  # nothing until that same gate validates it through the runtime.
  struct DevOverride
    include JSON::Serializable

    getter event_id : String
    getter run_id : String
    getter actor : String
    getter reason : String
    getter target_gate : String
    getter scope : String
    getter resulting_authority : String

    def initialize(
      @event_id : String,
      @run_id : String,
      @actor : String,
      @reason : String,
      @target_gate : String,
      @scope : String,
      @resulting_authority : String,
    )
    end
  end

  module DevOverrideValidation
    extend self

    DEV_AUTHORITIES       = {"R0", "R1", "R2", "R3"}
    AUTHORITY_RANK        = DEV_AUTHORITIES.each_with_index.to_h
    FORBIDDEN_EXACT_GATES = [
      "event_log",
      "event.logging",
      "event.log",
      "logging",
      "log",
    ]

    # Reject broad, untraceable, promotion, logging, or R4 requests.
    def validate_override_request(
      *,
      actor : String,
      reason : String,
      target_gate : String,
      scope : String,
      resulting_authority : String,
    ) : Nil
      {"actor" => actor, "reason" => reason, "target_gate" => target_gate, "scope" => scope}.each do |name, value|
        if value.strip.empty?
          raise DevOverrideError.new("dev override #{name} must be a non-empty string")
        end
      end
      unless DEV_AUTHORITIES.includes?(resulting_authority)
        raise DevOverrideError.new(
          "dev override resulting_authority must be one of R0, R1, R2, R3; " \
          "R4 governance authority is never available"
        )
      end
      if gate_forbidden?(target_gate)
        raise DevOverrideError.new("dev override cannot target non-bypassable gate #{target_gate.inspect}")
      end
    end

    # Whether a gate belongs to promotion or event-log authority.
    def gate_forbidden?(target_gate : String) : Bool
      normalized = target_gate.strip.downcase
      FORBIDDEN_EXACT_GATES.includes?(normalized) ||
        normalized == "promote" ||
        normalized.starts_with?("promote.") ||
        normalized == "promotion" ||
        normalized.starts_with?("promotion.") ||
        normalized.starts_with?("event_log.") ||
        normalized.starts_with?("event.logging.")
    end

    # Hydrate one valid receipt from an accepted event, else nil.
    def receipt_from_event(event : Event, run_id : String) : DevOverride?
      return nil unless event.type == "dev.override"

      payload = JSON.parse(event.payload).as_h
      actor = payload["actor"]?.try(&.as_s?)
      reason = payload["reason"]?.try(&.as_s?)
      target_gate = payload["target_gate"]?.try(&.as_s?)
      scope = payload["scope"]?.try(&.as_s?)
      resulting_authority = payload["resulting_authority"]?.try(&.as_s?)
      return nil unless actor && reason && target_gate && scope && resulting_authority
      return nil unless event.actor == actor

      begin
        validate_override_request(
          actor: actor, reason: reason, target_gate: target_gate,
          scope: scope, resulting_authority: resulting_authority,
        )
      rescue DevOverrideError
        return nil
      end

      DevOverride.new(
        event_id: event.id, run_id: run_id, actor: actor, reason: reason,
        target_gate: target_gate, scope: scope,
        resulting_authority: resulting_authority,
      )
    end

    # Whether a local grant covers `required` without reaching R4.
    def authority_allows?(granted : String, required : String) : Bool
      granted_rank = AUTHORITY_RANK[granted]?
      required_rank = AUTHORITY_RANK[required]?
      return false if granted_rank.nil? || required_rank.nil?
      required_rank <= granted_rank
    end
  end
end
