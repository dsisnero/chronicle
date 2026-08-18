require "../spec_helper"

# Prometheus text exposition (observability/prometheus.py, CONTRACT v0.8 #10):
# an in-memory `Metrics` implementation that records observations, plus a
# Sans-IO renderer that emits the Prometheus text exposition format (v0.0.4) —
# `# HELP` / `# TYPE` lines from the standard metric table, then one sample
# line per label set. The scrape HTTP endpoint stays at the platform edge.

describe Chronicle::PrometheusMetrics do
  it "implements the Metrics protocol and accumulates counters per label set" do
    metrics = Chronicle::PrometheusMetrics.new
    metrics.counter("activegraph_events_emitted_total", {"event_type" => "goal.created"})
    metrics.counter("activegraph_events_emitted_total", {"event_type" => "goal.created"})
    metrics.counter("activegraph_events_emitted_total", {"event_type" => "object.created"})

    text = Chronicle::Prometheus.render(metrics)
    text.should contain("# HELP activegraph_events_emitted_total Every event that lands in the graph's event log.")
    text.should contain("# TYPE activegraph_events_emitted_total counter")
    text.should contain(%(activegraph_events_emitted_total{event_type="goal.created"} 2))
    text.should contain(%(activegraph_events_emitted_total{event_type="object.created"} 1))
  end

  it "renders gauges with the latest value" do
    metrics = Chronicle::PrometheusMetrics.new
    metrics.gauge("activegraph_queue_depth", {} of String => String, 3.0)
    metrics.gauge("activegraph_queue_depth", {} of String => String, 1.0)

    text = Chronicle::Prometheus.render(metrics)
    text.should contain("# TYPE activegraph_queue_depth gauge")
    text.should contain("activegraph_queue_depth 1")
  end

  it "renders histograms with _sum and _count series" do
    metrics = Chronicle::PrometheusMetrics.new
    metrics.histogram("activegraph_behaviors_duration_seconds", {"behavior" => "worker"}, 0.25)
    metrics.histogram("activegraph_behaviors_duration_seconds", {"behavior" => "worker"}, 0.75)

    text = Chronicle::Prometheus.render(metrics)
    text.should contain("# TYPE activegraph_behaviors_duration_seconds histogram")
    text.should contain(%(activegraph_behaviors_duration_seconds_sum{behavior="worker"} 1))
    text.should contain(%(activegraph_behaviors_duration_seconds_count{behavior="worker"} 2))
  end

  it "escapes label values per the exposition format" do
    metrics = Chronicle::PrometheusMetrics.new
    metrics.counter("activegraph_sink_events_dropped_total", {"reason" => "quota exceeded, \"full\""}, 1.0)

    text = Chronicle::Prometheus.render(metrics)
    text.should contain(%(activegraph_sink_events_dropped_total{reason="quota exceeded, \\"full\\""} 1))
  end
end
