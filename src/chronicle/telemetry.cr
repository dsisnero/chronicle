require "tracing"

module Chronicle
  # Structured trace export for Chronicle agent operations.
  module Telemetry
    ROUTE_TARGET = "clarity_routing"

    def self.record_route_preview(decision : Routing::RouteDecision) : Nil
      meta = Tracing::Metadata.new("route.preview", ROUTE_TARGET, Tracing::Level::INFO)
      span = Tracing::Span.new(meta)
      return if span.disabled?

      span.record_field("intent", decision.intent.to_s)
      span.record_field("rule", decision.matched_rule)
      span.record_field("model", "#{decision.target.provider}/#{decision.target.model}")
      span.record_field("override", decision.override_used?.to_s)
      span.record_field("fallback", decision.fallback_used?.to_s)
      span.record_field("confidence", decision.classification.confidence.to_s)
      span.record_field("trace", decision.routing_reason)

      span.in_scope { }
    end
  end
end
