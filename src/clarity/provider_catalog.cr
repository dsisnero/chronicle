module Clarity
  # Platform-edge snapshot of provider availability. It turns configured
  # provider instances and credential references into deterministic facts that
  # the router can consume without touching environment variables itself.
  class ProviderCatalog
    def initialize(@config : Config)
    end

    def available_targets(policy : Routing::Policy) : Array(Routing::Target)
      policy.configured_targets.select { |target| available?(target) }
    end

    def available?(target : Routing::Target) : Bool
      unavailable_reason(target).nil?
    end

    def unavailable_reason(target : Routing::Target) : String?
      provider = @config.providers[target.provider]?
      return "provider not configured" unless provider
      return "provider disabled" if provider.disabled?
      return "missing credential" unless provider.credential_available?
      nil
    end
  end
end
