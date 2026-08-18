module Chronicle
  # In-memory Metrics implementation that records observations for the
  # Prometheus text exposition (CONTRACT v0.8 #10, upstream
  # observability/prometheus.py `PrometheusMetrics` adapted Sans-IO). The
  # scrape HTTP endpoint stays at the platform edge; `Prometheus.render`
  # emits the text exposition format.
  class PrometheusMetrics < Metrics
    @lock = Mutex.new
    @counters : Hash(String, Hash(String, Float64))
    @gauges : Hash(String, Hash(String, Float64))
    @histogram_sums : Hash(String, Hash(String, Float64))
    @histogram_counts : Hash(String, Hash(String, Int64))

    def initialize
      @counters = {} of String => Hash(String, Float64)
      @gauges = {} of String => Hash(String, Float64)
      @histogram_sums = {} of String => Hash(String, Float64)
      @histogram_counts = {} of String => Hash(String, Int64)
    end

    def counter(name : String, tags : Hash(String, String), value : Float64 = 1.0) : Nil
      @lock.synchronize do
        key = label_key(tags)
        @counters[name] ||= {} of String => Float64
        @counters[name][key] = (@counters[name][key]? || 0.0) + value
      end
    end

    def histogram(name : String, tags : Hash(String, String), value : Float64) : Nil
      @lock.synchronize do
        key = label_key(tags)
        @histogram_sums[name] ||= {} of String => Float64
        @histogram_counts[name] ||= {} of String => Int64
        @histogram_sums[name][key] = (@histogram_sums[name][key]? || 0.0) + value
        @histogram_counts[name][key] = (@histogram_counts[name][key]? || 0_i64) + 1
      end
    end

    def gauge(name : String, tags : Hash(String, String), value : Float64) : Nil
      @lock.synchronize do
        key = label_key(tags)
        @gauges[name] ||= {} of String => Float64
        @gauges[name][key] = value
      end
    end

    # Canonical, escaped label string (`k="v",k2="v2"`, sorted keys) shared
    # with the renderer; empty when the sample has no labels.
    def label_key(tags : Hash(String, String)) : String
      tags.to_a.sort_by(&.[0]).map { |key, value| %(#{key}="#{Prometheus.escape_label(value)}") }.join(",")
    end

    getter counters : Hash(String, Hash(String, Float64))
    getter gauges : Hash(String, Hash(String, Float64))
    getter histogram_sums : Hash(String, Hash(String, Float64))
    getter histogram_counts : Hash(String, Hash(String, Int64))
  end

  # Sans-IO renderer for the Prometheus text exposition format (v0.0.4).
  # `# HELP` / `# TYPE` lines come from the standard metric table; each
  # recorded sample emits one line. Histograms render their `_sum` / `_count`
  # series plus the `+Inf` bucket (bucket boundaries stay at the platform
  # edge). The scrape endpoint is not part of this module.
  module Prometheus
    extend self

    def render(metrics : PrometheusMetrics, table : Array(MetricSpec) = MetricsTable::METRIC_NAMES) : String
      specs = table.to_h { |spec| {spec.name, spec} }
      String.build do |io|
        metrics.counters.each do |name, samples|
          next unless spec = specs[name]?

          emit_header(io, spec)
          samples.each { |labels, value| emit_sample(io, name, labels, value) }
        end

        metrics.gauges.each do |name, samples|
          next unless spec = specs[name]?

          emit_header(io, spec)
          samples.each { |labels, value| emit_sample(io, name, labels, value) }
        end

        metrics.histogram_sums.each do |name, sums|
          next unless spec = specs[name]?

          counts = metrics.histogram_counts[name]? || {} of String => Int64
          emit_header(io, spec)
          sums.each do |labels, sum|
            count = counts[labels]? || 0_i64
            emit_sample(io, "#{name}_sum", labels, sum)
            emit_sample(io, "#{name}_count", labels, count.to_f)
            bucket_labels = labels.empty? ? %(le="+Inf") : "#{labels},le=\"+Inf\""
            emit_sample(io, "#{name}_bucket", bucket_labels, count.to_f)
          end
        end
      end
    end

    private def emit_header(io : IO, spec : MetricSpec) : Nil
      io << "# HELP " << spec.name << ' ' << spec.description << '\n'
      io << "# TYPE " << spec.name << ' ' << spec.kind << '\n'
    end

    private def emit_sample(io : IO, name : String, labels : String, value : Float64) : Nil
      if labels.empty?
        io << name << ' ' << format_number(value) << '\n'
      else
        io << name << '{' << labels << "} " << format_number(value) << '\n'
      end
    end

    private def format_number(value : Float64) : String
      if value == value.round
        value.round.to_i64.to_s
      else
        value.to_s
      end
    end

    # Escape a label value per the exposition format: backslash, double quote,
    # and newline (v0.0.4).
    def escape_label(value : String) : String
      value.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub('\n', "\\n")
    end
  end
end
