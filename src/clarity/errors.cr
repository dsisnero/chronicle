module Clarity
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
end
