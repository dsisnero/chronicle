require "json"

module Chronicle
  # The Metrics protocol — three methods, all best-effort, all
  # non-throwing (CONTRACT v0.8 #8–#10). No timers (use a histogram with a
  # latency value), no summaries, no custom types. Adding a metric is a
  # public API change; the standard table below is the operator contract.
  #
  # Implementations MUST tolerate unknown metric names. Unknown tag keys are
  # also accepted; cardinality discipline is the caller's job.
  abstract class Metrics
    abstract def counter(name : String, tags : Hash(String, String), value : Float64 = 1.0) : Nil
    abstract def histogram(name : String, tags : Hash(String, String), value : Float64) : Nil
    abstract def gauge(name : String, tags : Hash(String, String), value : Float64) : Nil
  end

  # Default Metrics implementation: does nothing. The runtime is fully
  # functional with NoOpMetrics.
  class NoOpMetrics < Metrics
    def counter(name : String, tags : Hash(String, String), value : Float64 = 1.0) : Nil
    end

    def histogram(name : String, tags : Hash(String, String), value : Float64) : Nil
    end

    def gauge(name : String, tags : Hash(String, String), value : Float64) : Nil
    end
  end

  # One documented metric: name, kind (counter | histogram | gauge), tag
  # set, and description. Source of truth for the standard metric list.
  struct MetricSpec
    getter name : String
    getter kind : String
    getter tags : Array(String)
    getter description : String

    def initialize(@name : String, @kind : String, @tags : Array(String), @description : String)
    end
  end

  # A metric-table violation: a counter/histogram declaring `run_id` as a
  # tag (CONTRACT v0.8 #C4 — run_id is gauge-only).
  class MetricsError < DomainError
  end

  # The documented standard metric table + cardinality-rule validation.
  # CONTRACT v0.8 #8–#10, #C4.
  module MetricsTable
    extend self

    METRIC_NAMES = [
      MetricSpec.new("activegraph_events_emitted_total", "counter", ["event_type"], "Every event that lands in the graph's event log."),
      MetricSpec.new("activegraph_behaviors_invoked_total", "counter", ["behavior"], "Each behavior invocation. Increments before the handler runs."),
      MetricSpec.new("activegraph_behaviors_failed_total", "counter", ["behavior", "reason"], "Behavior invocations that produced a behavior.failed event."),
      MetricSpec.new("activegraph_behaviors_duration_seconds", "histogram", ["behavior"], "Wall-clock duration of a behavior invocation (handler only)."),
      MetricSpec.new("activegraph_llm_calls_total", "counter", ["model"], "Every llm.requested event (cached and non-cached)."),
      MetricSpec.new("activegraph_llm_cache_hits_total", "counter", ["model"], "LLM calls served from the recorded-response cache."),
      MetricSpec.new("activegraph_llm_failed_total", "counter", ["model", "reason"], "LLM calls that failed before producing a usable response."),
      MetricSpec.new("activegraph_llm_tokens_in", "histogram", ["model"], "Input tokens reported by the provider per llm.responded."),
      MetricSpec.new("activegraph_llm_tokens_out", "histogram", ["model"], "Output tokens reported by the provider per llm.responded."),
      MetricSpec.new("activegraph_llm_cost_usd", "histogram", ["model"], "Per-call cost in USD as reported by the provider."),
      MetricSpec.new("activegraph_tools_calls_total", "counter", ["tool"], "Every tool.requested event (cached and non-cached)."),
      MetricSpec.new("activegraph_tools_cache_hits_total", "counter", ["tool"], "Tool calls served from the recorded-response cache."),
      MetricSpec.new("activegraph_tools_failed_total", "counter", ["tool", "reason"], "Tool calls that produced a tool.failed event."),
      MetricSpec.new("activegraph_tools_duration_seconds", "histogram", ["tool"], "Wall-clock duration of a tool invocation."),
      MetricSpec.new("activegraph_queue_depth", "gauge", [] of String, "Current depth of the runtime's event queue."),
      MetricSpec.new("activegraph_sink_queue_depth", "gauge", ["sink", "run_id"], "Waiting deliveries in one attached sink's bounded queue."),
      MetricSpec.new("activegraph_sink_events_delivered_total", "counter", ["sink"], "Events successfully handled by an attached sink."),
      MetricSpec.new("activegraph_sink_events_dropped_total", "counter", ["sink", "reason"], "Sink deliveries rejected or evicted under declared policy."),
      MetricSpec.new("activegraph_sink_errors_total", "counter", ["sink", "operation"], "Adapter lifecycle or on_event failures isolated by sink workers."),
      MetricSpec.new("activegraph_budget_cost_remaining_usd", "gauge", ["run_id"], "Remaining cost budget for an active run, USD."),
      MetricSpec.new("activegraph_budget_events_remaining", "gauge", ["run_id"], "Remaining event budget for an active run."),
      MetricSpec.new("activegraph_patterns_evaluated_total", "counter", [] of String, "Pattern evaluations across all behaviors."),
      MetricSpec.new("activegraph_patterns_evaluation_duration_seconds", "histogram", [] of String, "Per-evaluation duration of a pattern subscription."),
      MetricSpec.new("activegraph_replay_divergence_detected_total", "counter", ["reason"], "Replay-strict re-runs that diverged from the recorded log."),
    ]

    # Standard metric specs, in the documented order.
    def names : Array(MetricSpec)
      METRIC_NAMES
    end

    # Standard metric specs keyed by name.
    def by_name : Hash(String, MetricSpec)
      METRIC_NAMES.to_h { |spec| {spec.name, spec} }
    end

    # Enforce CONTRACT v0.8 #C4: run_id only appears on gauges. Raises
    # MetricsError if any counter or histogram declares run_id as a tag.
    def validate_cardinality_rule(metrics : Array(MetricSpec) = METRIC_NAMES) : Nil
      metrics.each do |spec|
        if spec.tags.includes?("run_id") && spec.kind != "gauge"
          raise MetricsError.new(
            "metric #{spec.name.inspect} (#{spec.kind}) lists run_id as a tag — " \
            "forbidden by the cardinality rule (run_id is gauge-only)."
          )
        end
      end
    end

    # Validate at load time so any in-tree edit fails loud.
    validate_cardinality_rule
  end
end
