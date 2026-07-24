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

  class OverrideNotAllowedError < DomainError
  end

  class NoLocalTargetError < DomainError
  end

  class ContextBudgetError < DomainError
  end

  class GraphProjectionError < DomainError
  end

  class ReplayDivergenceError < DomainError
  end

  class ApprovalError < DomainError
  end

  class InvalidLogEncodingError < DomainError
  end
end
