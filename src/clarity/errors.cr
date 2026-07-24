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
end
