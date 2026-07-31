require "../spec_helper"

private alias T = Chronicle::Routing::Target
private alias I = Chronicle::Routing::Intent
private alias PM = Chronicle::Routing::PermissionMode

private def sample_decision
  T.new("deepseek", "deepseek-v4-flash")
  classification = Chronicle::Routing::Classification.new(I::Chat, nil, true, 1.0)
  cost = Chronicle::Routing::CostEstimate.new(0.001, 0.002)

  Chronicle::Routing::RouteDecision.new(
    I::Chat,
    classification,
    T.new("deepseek", "deepseek-v4-flash"),
    [] of Chronicle::Routing::Target,
    "chat rule",
    "priority=10, specificity=1",
    false,
    false,
    [] of Chronicle::Routing::ContextCandidate,
    [] of Chronicle::Routing::ExcludedContext,
    {} of String => PM,
    cost,
  )
end

describe Chronicle::Telemetry do
  it "emits a route.preview span with decision attributes" do
    subscriber = Tracing::MockSubscriber.new
    dispatch = Tracing::Core::Dispatch.new(subscriber)

    Tracing::Core::Dispatch.with_default(dispatch) do
      Chronicle::Telemetry.record_route_preview(sample_decision)
    end

    subscriber.spans.size.should eq(1)
    attrs, _id = subscriber.spans.first
    attrs.metadata.name.should eq("route.preview")
    attrs.metadata.target.should eq("clarity_routing")
  end

  it "records route decision attributes on the span metadata" do
    subscriber = Tracing::MockSubscriber.new
    dispatch = Tracing::Core::Dispatch.new(subscriber)

    Tracing::Core::Dispatch.with_default(dispatch) do
      Chronicle::Telemetry.record_route_preview(sample_decision)
    end

    subscriber.spans.size.should eq(1)
    attrs, _id = subscriber.spans.first
    attrs.metadata.name.should eq("route.preview")
    attrs.metadata.level.should eq(Tracing::Level::INFO)
  end
end
