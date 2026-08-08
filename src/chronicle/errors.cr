module Chronicle
  # Base class for invalid inputs rejected by the deterministic core.
  class DomainError < ArgumentError
  end

  class InvalidEventError < DomainError
  end

  class EventSequenceError < DomainError
  end

  class DuplicateEventError < DomainError
  end

  class CausalParentError < DomainError
  end

  class InvalidRoutingPolicyError < DomainError
  end

  class NoRouteError < DomainError
  end

  class ProviderNotAvailableError < DomainError
  end

  # A platform-edge provider failure that may safely advance a pre-recorded
  # fallback list. Configuration, policy, and capability errors are not this.
  class RetryableProviderError < DomainError
  end

  class OverrideNotAllowedError < DomainError
  end

  class NoLocalTargetError < DomainError
  end

  class ContextBudgetError < DomainError
  end

  class GraphProjectionError < DomainError
  end

  # A behavior tried to inject a reserved field (e.g. provenance) through
  # object/relation data. Ported from activegraph's ReservedFieldError.
  class ReservedFieldError < DomainError
  end

  class ReplayDivergenceError < DomainError
  end

  class ApprovalError < DomainError
  end

  class InvalidLogEncodingError < DomainError
  end

  class PackError < DomainError
  end

  # A tool call failed: unpermitted external I/O, network error, or timeout.
  # Ported from activegraph's ToolError.
  class ToolError < DomainError
  end

  # A dev.override request or receipt that violates run-local, log-backed
  # governance rules. Ported from activegraph's ValueError on
  # validate_override_request / gate_is_forbidden.
  class DevOverrideError < DomainError
  end

  # A runtime operation requires a state the runtime is not in (e.g.
  # `fork` on a non-SQLite-backed runtime). Ported from activegraph's
  # IncompatibleRuntimeState.
  class IncompatibleRuntimeState < DomainError
  end

  # An event id referenced by an operation does not exist in the run.
  # Ported from activegraph's EventNotFoundError.
  class EventNotFoundError < DomainError
  end

  # A promote() plan contained one or more both-sides/referential-integrity
  # conflicts; nothing was mutated. Ported from activegraph's
  # PromoteConflictError (CONTRACT v1.3 #4).
  class PromoteConflictError < DomainError
    getter conflicts : Array(PromoteConflict)

    def initialize(conflicts : Array(PromoteConflict))
      @conflicts = conflicts
      super("promote conflicts: #{conflicts.map(&.id).join(", ")}")
    end
  end

  # promote() called with a fork whose store lineage does not record this run
  # as its direct parent. Ported from activegraph's PromoteLineageError.
  class PromoteLineageError < DomainError
  end
end
