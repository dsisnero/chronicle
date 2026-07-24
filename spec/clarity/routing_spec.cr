require "../spec_helper"

module RoutingSpecHelper
  extend self

  alias Intent = Clarity::Routing::Intent
  alias ContextKind = Clarity::Routing::ContextKind
  alias PermissionMode = Clarity::Routing::PermissionMode

  def target(
    provider : String,
    model : String,
    remote : Bool = true,
    input_token_cost : Float64 = 0.001,
    output_token_cost : Float64 = 0.002,
  ) : Clarity::Routing::Target
    Clarity::Routing::Target.new(provider, model, remote, input_token_cost, output_token_cost)
  end

  def policy(
    classification_rules : Array(Clarity::Routing::ClassificationRule) = [] of Clarity::Routing::ClassificationRule,
    routing_rules : Array(Clarity::Routing::RouteRule) = [] of Clarity::Routing::RouteRule,
    default_target : Clarity::Routing::Target = target("local", "fallback", false),
    default_fallbacks : Array(Clarity::Routing::Target) = [] of Clarity::Routing::Target,
    token_budget : Int32 = 100,
    default_permissions : Hash(String, PermissionMode) = {"shell" => PermissionMode::Ask},
  ) : Clarity::Routing::Policy
    Clarity::Routing::Policy.new(
      classification_rules,
      routing_rules,
      default_target,
      default_fallbacks,
      token_budget,
      default_permissions
    )
  end

  def request(
    text : String,
    explicit_intent : Intent? = nil,
    explicit_target : Clarity::Routing::Target? = nil,
    paths : Array(String) = [] of String,
    context : Array(Clarity::Routing::ContextCandidate) = [] of Clarity::Routing::ContextCandidate,
    focus_path : String? = nil,
  ) : Clarity::Routing::Request
    Clarity::Routing::Request.new(text, explicit_intent, explicit_target, paths, context, focus_path, 20)
  end

  def context(
    id : String,
    kind : ContextKind,
    tokens : Int32,
    path : String? = nil,
    restricted : Bool = false,
  ) : Clarity::Routing::ContextCandidate
    Clarity::Routing::ContextCandidate.new(id, kind, tokens, path, restricted)
  end
end

alias RoutingIntent = Clarity::Routing::Intent
alias RoutingContextKind = Clarity::Routing::ContextKind
alias RoutingPermissionMode = Clarity::Routing::PermissionMode

describe Clarity::Routing::Router do
  it "uses an explicit intent over keyword classification" do
    policy = RoutingSpecHelper.policy(
      classification_rules: [
        Clarity::Routing::ClassificationRule.new("review words", RoutingIntent::Review, 10, ["review"]),
      ]
    )
    request = RoutingSpecHelper.request("review this diff", explicit_intent: RoutingIntent::Plan)

    decision = Clarity::Routing::Router.new.preview(
      request,
      policy,
      [policy.default_target]
    )

    decision.intent.should eq(RoutingIntent::Plan)
    decision.classification.explicit?.should be_true
  end

  it "chooses lower priority before a more specific route" do
    general = Clarity::Routing::RouteRule.new(
      "all edits", 10, RoutingIntent::Edit, nil,
      RoutingSpecHelper.target("openai", "general")
    )
    specific = Clarity::Routing::RouteRule.new(
      "auth edits", 20, RoutingIntent::Edit, "src/auth/",
      RoutingSpecHelper.target("anthropic", "auth")
    )
    policy = RoutingSpecHelper.policy(routing_rules: [general, specific])
    request = RoutingSpecHelper.request("fix auth", explicit_intent: RoutingIntent::Edit, paths: ["src/auth/login.cr"])

    decision = Clarity::Routing::Router.new.preview(
      request,
      policy,
      [general.target, specific.target]
    )

    decision.matched_rule.should eq("all edits")
    decision.target.should eq(general.target)
    decision.routing_reason.should eq("priority=10, specificity=1")
  end

  it "chooses the more specific route when priorities tie" do
    general = Clarity::Routing::RouteRule.new(
      "all edits", 10, RoutingIntent::Edit, nil,
      RoutingSpecHelper.target("openai", "general")
    )
    specific = Clarity::Routing::RouteRule.new(
      "auth edits", 10, RoutingIntent::Edit, "src/auth/",
      RoutingSpecHelper.target("anthropic", "auth")
    )
    policy = RoutingSpecHelper.policy(routing_rules: [general, specific])
    request = RoutingSpecHelper.request("fix auth", explicit_intent: RoutingIntent::Edit, paths: ["src/auth/login.cr"])

    decision = Clarity::Routing::Router.new.preview(
      request,
      policy,
      [general.target, specific.target]
    )

    decision.matched_rule.should eq("auth edits")
    decision.target.should eq(specific.target)
  end

  it "uses declaration order when priority and specificity tie" do
    first = Clarity::Routing::RouteRule.new(
      "first edit rule", 10, RoutingIntent::Edit, nil,
      RoutingSpecHelper.target("openai", "first")
    )
    second = Clarity::Routing::RouteRule.new(
      "second edit rule", 10, RoutingIntent::Edit, nil,
      RoutingSpecHelper.target("anthropic", "second")
    )
    policy = RoutingSpecHelper.policy(routing_rules: [first, second])

    decision = Clarity::Routing::Router.new.preview(
      RoutingSpecHelper.request("edit", explicit_intent: RoutingIntent::Edit),
      policy,
      [first.target, second.target]
    )

    decision.matched_rule.should eq("first edit rule")
  end

  it "uses a configured explicit target before rule selection" do
    rule_target = RoutingSpecHelper.target("openai", "rule")
    override_target = RoutingSpecHelper.target("local", "override", false)
    rule = Clarity::Routing::RouteRule.new("edits", 10, RoutingIntent::Edit, nil, rule_target)
    policy = RoutingSpecHelper.policy(
      routing_rules: [rule],
      default_fallbacks: [override_target]
    )

    decision = Clarity::Routing::Router.new.preview(
      RoutingSpecHelper.request(
        "edit",
        explicit_intent: RoutingIntent::Edit,
        explicit_target: override_target
      ),
      policy,
      [rule_target, override_target]
    )

    decision.target.should eq(override_target)
    decision.override_used?.should be_true
    decision.routing_reason.should eq("explicit target override")
  end

  it "applies privacy before stable context budgeting" do
    remote = RoutingSpecHelper.target("openai", "remote")
    policy = RoutingSpecHelper.policy(default_target: remote, token_budget: 8)
    request = RoutingSpecHelper.request(
      "review",
      context: [
        RoutingSpecHelper.context("restricted", RoutingContextKind::ExplicitlyAttached, 1, restricted: true),
        RoutingSpecHelper.context("history", RoutingContextKind::HistoryBuffer, 4),
        RoutingSpecHelper.context("diff", RoutingContextKind::GitDiff, 4),
        RoutingSpecHelper.context("memory", RoutingContextKind::MemoryFact, 4),
      ]
    )

    decision = Clarity::Routing::Router.new.preview(request, policy, [remote])

    decision.included_context.map(&.id).should eq(["diff", "history"])
    decision.excluded_context.map(&.id).should eq(["restricted", "memory"])
    decision.excluded_context.map(&.reason).should eq(["restricted for remote", "token budget exceeded"])
    decision.estimated_cost.minimum.should eq(0.008)
    decision.estimated_cost.maximum.should eq(0.048)
  end

  it "uses the declared fallback when the primary target is unavailable" do
    primary = RoutingSpecHelper.target("openai", "primary")
    fallback = RoutingSpecHelper.target("local", "fallback", false)
    rule = Clarity::Routing::RouteRule.new("planning", 10, RoutingIntent::Plan, nil, primary, [fallback])
    policy = RoutingSpecHelper.policy(routing_rules: [rule])

    decision = Clarity::Routing::Router.new.preview(
      RoutingSpecHelper.request("plan", explicit_intent: RoutingIntent::Plan),
      policy,
      [fallback]
    )

    decision.target.should eq(fallback)
    decision.fallback_used?.should be_true
  end

  it "rejects a route when no primary or fallback target is available" do
    target = RoutingSpecHelper.target("openai", "missing")
    policy = RoutingSpecHelper.policy(default_target: target)

    expect_raises(Clarity::NoRouteError, "no eligible target") do
      Clarity::Routing::Router.new.preview(
        RoutingSpecHelper.request("hello"),
        policy,
        [] of Clarity::Routing::Target
      )
    end
  end

  it "rejects a rule that widens a default permission" do
    target = RoutingSpecHelper.target("openai", "remote")
    rule = Clarity::Routing::RouteRule.new(
      "unsafe", 10, RoutingIntent::Edit, nil, target,
      [] of Clarity::Routing::Target,
      {"shell" => RoutingPermissionMode::Allow}
    )
    policy = RoutingSpecHelper.policy(
      routing_rules: [rule],
      default_permissions: {"shell" => RoutingPermissionMode::Deny}
    )

    expect_raises(Clarity::InvalidRoutingPolicyError, "cannot widen permission") do
      Clarity::Routing::Router.new.preview(
        RoutingSpecHelper.request("edit", explicit_intent: RoutingIntent::Edit),
        policy,
        [target]
      )
    end
  end
end
