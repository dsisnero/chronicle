require "../spec_helper"

# Recording test double for the Metrics protocol (upstream RecordingMetrics).
class RecordingMetrics < Chronicle::Metrics
  getter counters = [] of Tuple(String, Hash(String, String), Float64)
  getter histograms = [] of Tuple(String, Hash(String, String), Float64)
  getter gauges = [] of Tuple(String, Hash(String, String), Float64)

  def counter(name : String, tags : Hash(String, String), value : Float64 = 1.0) : Nil
    @counters << {name, tags, value}
  end

  def histogram(name : String, tags : Hash(String, String), value : Float64) : Nil
    @histograms << {name, tags, value}
  end

  def gauge(name : String, tags : Hash(String, String), value : Float64) : Nil
    @gauges << {name, tags, value}
  end
end

private def metrics_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel), RecordingMetrics}
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  metrics = RecordingMetrics.new
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, metrics: metrics)
  {store, graph, rt, metrics}
end

private def metrics_runtime_counters(store, graph, rt, metrics) : Array(Tuple(String, Hash(String, String), Float64))
  metrics.counters
end

describe Chronicle::Metrics do
  describe "NoOpMetrics" do
    it "satisfies the protocol and does not throw (test_noop_satisfies_protocol)" do
      m = Chronicle::NoOpMetrics.new
      m.counter("x", {} of String => String)
      m.histogram("x", {} of String => String, 1.0)
      m.gauge("x", {} of String => String, 1.0)
    end

    it "does not throw on unknown names (test_noop_does_not_throw_on_unknown_names)" do
      m = Chronicle::NoOpMetrics.new
      m.counter("never_registered", {"random" => "tag"}, 42.0)
    end
  end
end

describe Chronicle::MetricsTable do
  it "passes the cardinality rule for the built-in table (test_cardinality_rule_passes)" do
    Chronicle::MetricsTable.validate_cardinality_rule
  end

  it "allows run_id only on gauges (test_run_id_only_on_gauges)" do
    Chronicle::MetricsTable.names.each do |spec|
      if spec.tags.includes?("run_id")
        spec.kind.should eq("gauge")
      end
    end
  end

  it "catches a cardinality violation (test_cardinality_rule_catches_violation)" do
    bad = [
      Chronicle::MetricSpec.new("bad_counter_total", "counter", ["run_id"], "x"),
    ]
    expect_raises(Chronicle::MetricsError) do
      Chronicle::MetricsTable.validate_cardinality_rule(bad)
    end
  end

  it "keeps the anchored standard metric names (test_known_metric_names_present)" do
    %w[
      activegraph_events_emitted_total
      activegraph_behaviors_invoked_total
      activegraph_behaviors_failed_total
      activegraph_llm_calls_total
      activegraph_llm_cache_hits_total
      activegraph_tools_calls_total
      activegraph_tools_cache_hits_total
      activegraph_queue_depth
      activegraph_budget_cost_remaining_usd
      activegraph_replay_divergence_detected_total
    ].each do |name|
      Chronicle::MetricsTable.by_name.has_key?(name).should be_true
    end
  end

  it "names counters with a _total suffix (test_counters_end_in_total)" do
    Chronicle::MetricsTable.names.each do |spec|
      if spec.kind == "counter"
        spec.name.ends_with?("_total").should be_true
      end
    end
  end

  it "names duration histograms with a _seconds suffix (test_duration_histograms_end_in_seconds)" do
    Chronicle::MetricsTable.names.each do |spec|
      if spec.kind == "histogram" && spec.name.includes?("duration")
        spec.name.ends_with?("_seconds").should be_true
      end
    end
  end

  it "names cost histograms with a _usd suffix (test_cost_histograms_end_in_usd)" do
    Chronicle::MetricsTable.names.each do |spec|
      if spec.kind == "histogram" && spec.name.includes?("cost")
        spec.name.ends_with?("_usd").should be_true
      end
    end
  end
end

describe Chronicle::Runtime do
  it "emits activegraph_events_emitted_total with an event_type tag" do
    store, graph, rt, metrics = metrics_runtime
    rt.run_until_idle
    graph.add_object("task", %({"x":1}))

    counters = metrics_runtime_counters(store, graph, rt, metrics)
    counters.any? { |(name, tags, _)| name == "activegraph_events_emitted_total" && tags.has_key?("event_type") }.should be_true
  end
end
