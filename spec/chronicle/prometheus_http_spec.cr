require "../spec_helper"
require "http/client"

private def with_prometheus_server(metrics : Chronicle::PrometheusMetrics, &)
  server = Chronicle::Prometheus::ScrapeServer.new(metrics)
  address = server.start
  yield "http://#{address.address}:#{address.port}", server
ensure
  server.try &.close
end

describe Chronicle::Prometheus::ScrapeServer do
  it "serves Prometheus text at GET /metrics" do
    metrics = Chronicle::PrometheusMetrics.new
    metrics.counter("activegraph_events_emitted_total", {"event_type" => "goal.created"})

    with_prometheus_server(metrics) do |url, _server|
      response = HTTP::Client.get("#{url}/metrics")

      response.status_code.should eq(200)
      response.headers["Content-Type"].should eq("text/plain; version=0.0.4; charset=utf-8")
      response.body.should contain("activegraph_events_emitted_total{event_type=\"goal.created\"} 1")
    end
  end

  it "returns a bounded 404 response for an unknown path" do
    with_prometheus_server(Chronicle::PrometheusMetrics.new) do |url, _server|
      response = HTTP::Client.get("#{url}/not-metrics")

      response.status_code.should eq(404)
      response.headers["Content-Type"].should eq("text/plain; charset=utf-8")
      response.body.should eq("not found\n")
    end
  end

  it "rejects methods other than GET without rendering metrics" do
    metrics = Chronicle::PrometheusMetrics.new
    metrics.counter("activegraph_events_emitted_total", {"event_type" => "goal.created"})

    with_prometheus_server(metrics) do |url, _server|
      response = HTTP::Client.post("#{url}/metrics", body: "ignored")

      response.status_code.should eq(405)
      response.headers["Allow"].should eq("GET")
      response.body.should eq("method not allowed\n")
    end
  end

  it "closes its listener and makes close idempotent" do
    server = Chronicle::Prometheus::ScrapeServer.new(Chronicle::PrometheusMetrics.new)
    server.start

    server.close
    server.closed?.should be_true
    server.close
  end

  it "requires positive request and header bounds" do
    metrics = Chronicle::PrometheusMetrics.new

    expect_raises(ArgumentError, "max_request_line_size must be positive") do
      Chronicle::Prometheus::ScrapeServer.new(metrics, max_request_line_size: 0)
    end
    expect_raises(ArgumentError, "max_headers_size must be positive") do
      Chronicle::Prometheus::ScrapeServer.new(metrics, max_headers_size: 0)
    end
  end
end
