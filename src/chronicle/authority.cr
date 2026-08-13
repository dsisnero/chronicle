module Chronicle
  # Canonical action-class authority evaluation (CONTRACT v1.9 #1–#3).
  # Ported from activegraph.runtime.authority. `action_class` with the closed
  # set `R0 | R1 | R2 | R3 | R4` is the canonical field for authority
  # decisions; this module holds the pure decision logic.
  #
  # Invariants (the point, restated from the contract):
  #
  # * The class set and the ceiling set are CLOSED. No value outside them
  #   ever evaluates to anything but fail-closed approval.
  # * There is NO mapping from the legacy `risk_class` vocabulary to action
  #   classes — this module never sees a risk class, by construction.
  # * `R4` routes to the dedicated governance gate at every ceiling.
  # * `R3` requires approval at every ceiling.
  # * Only `R0`–`R2` are ever auto-eligible, and only up to the EFFECTIVE
  #   ceiling: the stricter of the instance ceiling and any caller-supplied
  #   per-capability ceiling. Local policy can lower, never raise.
  # * A missing or invalid `action_class` fails closed to approval.
  module Authority
    extend self

    # The closed canonical consequence classes, lowest to highest.
    ACTION_CLASSES = ["R0", "R1", "R2", "R3", "R4"]

    # The closed automatic-ceiling values, lowest to highest. `R3` and `R4`
    # are deliberately unrepresentable as ceilings: no product request can
    # make an outward or governance action routine (CONTRACT v1.9 #2).
    AUTHORITY_CEILINGS = ["none", "R0", "R1", "R2"]

    DECISION_AUTO_APPROVE     = "auto_approve"
    DECISION_REQUIRE_APPROVAL = "require_approval"
    DECISION_GOVERNANCE_GATE  = "governance_gate"

    CLASS_RANK = ACTION_CLASSES.each_with_index.to_h
    # Ceiling ranks share the class scale so "class <= ceiling" is one
    # comparison: none sits below R0 (nothing auto-approves), R0..R2 align
    # with their class ranks.
    CEILING_RANK = {"none" => -1, "R0" => 0, "R1" => 1, "R2" => 2}

    # One evaluated authority decision on the new action-class path.
    # Mirrors the `authority.decision` audit payload (CONTRACT v1.9 #3).
    struct AuthorityDecision
      getter capability : String
      getter action_class : String
      getter ceiling : String
      getter capability_ceiling : String?
      getter effective_ceiling : String
      getter matched_policy : String
      getter decision : String
      getter reason : String
      getter event_id : String

      def initialize(
        @capability : String,
        @action_class : String,
        @ceiling : String,
        @capability_ceiling : String?,
        @effective_ceiling : String,
        @matched_policy : String,
        @decision : String,
        @reason : String,
        @event_id : String = "",
      )
      end

      def auto_approved : Bool
        @decision == DECISION_AUTO_APPROVE
      end
    end

    # Reject a ceiling value outside `none | R0 | R1 | R2`. Raises
    # ArgumentError (the Crystal analogue of upstream ValueError) naming the
    # closed set — used by the explicit `set_authority_ceiling` API, where a
    # bad value is a caller error that must be loud (unlike evaluation-time
    # inputs, which fail closed).
    def validate_ceiling(value : String) : Nil
      return if AUTHORITY_CEILINGS.includes?(value)

      raise ArgumentError.new(
        "authority ceiling must be one of #{AUTHORITY_CEILINGS.join(" | ")}; " \
        "got #{value.inspect}. R3 and R4 are never valid ceilings — outward " \
        "and governance actions cannot be made routine (CONTRACT v1.9 #2)."
      )
    end

    # The one policy decision on the new authority path, as a pure function.
    # Evaluation order is FIXED (CONTRACT v1.9 #2):
    #
    # 1. missing/invalid `action_class` (or an invalid `capability_ceiling`)
    #    → `require_approval`, fail closed;
    # 2. `R4` → `governance_gate`, always;
    # 3. `R3` → `require_approval`, always;
    # 4. `R0`–`R2` → `auto_approve` iff the class rank is at or below the
    #    effective ceiling (the stricter of `ceiling` and
    #    `capability_ceiling`), else `require_approval` with the rule that
    #    blocked it (`above_ceiling` / `stricter_local_policy`).
    #
    # `ceiling` must already be a valid ceiling value — the runtime only ever
    # passes a value that went through `validate_ceiling`. The legacy
    # `risk_class` vocabulary is not an input here and never participates.
    def evaluate_action_authority(
      *,
      capability : String,
      action_class : String,
      ceiling : String,
      capability_ceiling : String? = nil,
    ) : AuthorityDecision
      validate_ceiling(ceiling)

      if action_class.empty?
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: ceiling,
          matched_policy: "fail_closed_missing_action_class",
          decision: DECISION_REQUIRE_APPROVAL,
          reason: "no canonical action_class is declared for this capability; capabilities without one are ineligible for earned auto-approval (ADR 0016) — routed to approval",
        )
      end
      unless CLASS_RANK.has_key?(action_class)
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: ceiling,
          matched_policy: "fail_closed_invalid_action_class",
          decision: DECISION_REQUIRE_APPROVAL,
          reason: "action_class #{action_class.inspect} is outside the closed set #{ACTION_CLASSES.join(" | ")}; failing closed to approval",
        )
      end
      if (cc = capability_ceiling) && !CEILING_RANK.has_key?(cc)
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: ceiling,
          matched_policy: "fail_closed_invalid_capability_ceiling",
          decision: DECISION_REQUIRE_APPROVAL,
          reason: "capability_ceiling #{cc.inspect} is outside the closed set #{AUTHORITY_CEILINGS.join(" | ")}; a garbled local policy must never widen anything — failing closed",
        )
      end

      if action_class == "R4"
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: ceiling,
          matched_policy: "governance_gate_r4",
          decision: DECISION_GOVERNANCE_GATE,
          reason: "R4 governance actions always use the dedicated governance gate; no ceiling or level makes them routine",
        )
      end
      if action_class == "R3"
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: ceiling,
          matched_policy: "approval_required_r3",
          decision: DECISION_REQUIRE_APPROVAL,
          reason: "R3 outward actions require approval at every ceiling and every level",
        )
      end

      # R0–R2: compare against the effective (stricter) ceiling.
      instance_rank = CEILING_RANK[ceiling]
      effective = ceiling
      effective_rank = instance_rank
      if cc = capability_ceiling
        local_rank = CEILING_RANK[cc]
        if local_rank < effective_rank
          effective = cc
          effective_rank = local_rank
        end
      end
      class_rank = CLASS_RANK[action_class]

      if class_rank <= effective_rank
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: effective,
          matched_policy: "within_ceiling",
          decision: DECISION_AUTO_APPROVE,
          reason: "#{action_class} is at or below the effective automatic ceiling #{effective.inspect}",
        )
      end
      if class_rank <= instance_rank
        return AuthorityDecision.new(
          capability: capability, action_class: action_class,
          ceiling: ceiling, capability_ceiling: capability_ceiling,
          effective_ceiling: effective,
          matched_policy: "stricter_local_policy",
          decision: DECISION_REQUIRE_APPROVAL,
          reason: "#{action_class} is within the instance ceiling #{ceiling.inspect} but above the stricter capability ceiling #{capability_ceiling.inspect}; local policy may always lower the ceiling",
        )
      end
      AuthorityDecision.new(
        capability: capability, action_class: action_class,
        ceiling: ceiling, capability_ceiling: capability_ceiling,
        effective_ceiling: effective,
        matched_policy: "above_ceiling",
        decision: DECISION_REQUIRE_APPROVAL,
        reason: "#{action_class} is above the instance automatic ceiling #{ceiling.inspect}; routed to approval",
      )
    end
  end
end
