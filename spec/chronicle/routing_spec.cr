require "../spec_helper"

module RoutingSpecHelper
  extend self

  alias Intent = Chronicle::Routing::Intent
  alias ContextKind = Chronicle::Routing::ContextKind
  alias PermissionMode = Chronicle::Routing::PermissionMode

  def target(
    provider : String,
    model : String,
    remote : Bool = true,
    input_token_cost : Float64 = 0.001,
    output_token_cost : Float64 = 0.002,
  ) : Chronicle::Routing::Target
    Chronicle::Routing::Target.new(provider, model, remote, input_token_cost, output_token_cost)
  end

  def policy(
    classification_rules : Array(Chronicle::Routing::ClassificationRule) = [] of Chronicle::Routing::ClassificationRule,
    routing_rules : Array(Chronicle::Routing::RouteRule) = [] of Chronicle::Routing::RouteRule,
    default_target : Chronicle::Routing::Target = target("local", "fallback", false),
    default_fallbacks : Array(Chronicle::Routing::Target) = [] of Chronicle::Routing::Target,
    token_budget : Int32 = 100,
    default_permissions : Hash(String, PermissionMode) = {"shell" => PermissionMode::Ask},
  ) : Chronicle::Routing::Policy
    Chronicle::Routing::Policy.new(
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
    explicit_target : Chronicle::Routing::Target? = nil,
    paths : Array(String) = [] of String,
    context : Array(Chronicle::Routing::ContextCandidate) = [] of Chronicle::Routing::ContextCandidate,
    focus_path : String? = nil,
  ) : Chronicle::Routing::Request
    Chronicle::Routing::Request.new(text, explicit_intent, explicit_target, paths, context, focus_path, 20)
  end

  def context(
    id : String,
    kind : ContextKind,
    tokens : Int32,
    path : String? = nil,
    restricted : Bool = false,
    required : Bool = false,
  ) : Chronicle::Routing::ContextCandidate
    Chronicle::Routing::ContextCandidate.new(id, kind, tokens, path, restricted, required)
  end
end

alias RoutingIntent = Chronicle::Routing::Intent
alias RoutingContextKind = Chronicle::Routing::ContextKind
alias RoutingPermissionMode = Chronicle::Routing::PermissionMode

describe Chronicle::Routing::Router do
  it "uses an explicit intent over keyword classification" do
    policy = RoutingSpecHelper.policy(
      classification_rules: [
        Chronicle::Routing::ClassificationRule.new("review words", RoutingIntent::Review, 10, ["review"]),
      ]
    )
    request = RoutingSpecHelper.request("review this diff", explicit_intent: RoutingIntent::Plan)

    decision = Chronicle::Routing::Router.new.preview(
      request,
      policy,
      [policy.default_target]
    )

    decision.intent.should eq(RoutingIntent::Plan)
    decision.classification.explicit?.should be_true
  end

  it "chooses lower priority before a more specific route" do
    general = Chronicle::Routing::RouteRule.new(
      "all edits",
      RoutingSpecHelper.target("openai", "general"),
      priority: 10,
      intent: RoutingIntent::Edit,
    )
    specific = Chronicle::Routing::RouteRule.new(
      "auth edits",
      RoutingSpecHelper.target("anthropic", "auth"),
      priority: 20,
      intent: RoutingIntent::Edit,
      paths: ["src/auth/**"],
    )
    policy = RoutingSpecHelper.policy(routing_rules: [general, specific])
    request = RoutingSpecHelper.request("fix auth", explicit_intent: RoutingIntent::Edit, paths: ["src/auth/login.cr"])

    decision = Chronicle::Routing::Router.new.preview(
      request,
      policy,
      [general.target, specific.target]
    )

    decision.matched_rule.should eq("all edits")
    decision.target.should eq(general.target)
    decision.routing_reason.should eq("priority=10, specificity=1")
  end

  it "chooses the more specific route when priorities tie" do
    general = Chronicle::Routing::RouteRule.new(
      "all edits",
      RoutingSpecHelper.target("openai", "general"),
      priority: 10,
      intent: RoutingIntent::Edit,
    )
    specific = Chronicle::Routing::RouteRule.new(
      "auth edits",
      RoutingSpecHelper.target("anthropic", "auth"),
      priority: 10,
      intent: RoutingIntent::Edit,
      paths: ["src/auth/**"],
    )
    policy = RoutingSpecHelper.policy(routing_rules: [general, specific])
    request = RoutingSpecHelper.request("fix auth", explicit_intent: RoutingIntent::Edit, paths: ["src/auth/login.cr"])

    decision = Chronicle::Routing::Router.new.preview(
      request,
      policy,
      [general.target, specific.target]
    )

    decision.matched_rule.should eq("auth edits")
    decision.target.should eq(specific.target)
  end

  it "uses declaration order when priority and specificity tie" do
    first = Chronicle::Routing::RouteRule.new(
      "first edit rule",
      RoutingSpecHelper.target("openai", "first"),
      priority: 10,
      intent: RoutingIntent::Edit,
    )
    second = Chronicle::Routing::RouteRule.new(
      "second edit rule",
      RoutingSpecHelper.target("anthropic", "second"),
      priority: 10,
      intent: RoutingIntent::Edit,
    )
    policy = RoutingSpecHelper.policy(routing_rules: [first, second])

    decision = Chronicle::Routing::Router.new.preview(
      RoutingSpecHelper.request("edit", explicit_intent: RoutingIntent::Edit),
      policy,
      [first.target, second.target]
    )

    decision.matched_rule.should eq("first edit rule")
  end

  it "uses a configured explicit target before rule selection" do
    rule_target = RoutingSpecHelper.target("openai", "rule")
    override_target = RoutingSpecHelper.target("local", "override", false)
    rule = Chronicle::Routing::RouteRule.new("edits", rule_target, intent: RoutingIntent::Edit)
    policy = RoutingSpecHelper.policy(
      routing_rules: [rule],
      default_fallbacks: [override_target]
    )

    decision = Chronicle::Routing::Router.new.preview(
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

    decision = Chronicle::Routing::Router.new.preview(request, policy, [remote])

    decision.included_context.map(&.id).should eq(["diff", "history"])
    decision.excluded_context.map(&.id).should eq(["restricted", "memory"])
    decision.excluded_context.map(&.reason).should eq(["restricted for remote", "token budget exceeded"])
    decision.estimated_cost.minimum.should eq(0.008)
    decision.estimated_cost.maximum.should eq(0.048)
  end

  it "uses the declared fallback when the primary target is unavailable" do
    primary = RoutingSpecHelper.target("openai", "primary")
    fallback = RoutingSpecHelper.target("local", "fallback", false)
    rule = Chronicle::Routing::RouteRule.new("planning", primary, priority: 10, intent: RoutingIntent::Plan, fallbacks: [fallback])
    policy = RoutingSpecHelper.policy(routing_rules: [rule])

    decision = Chronicle::Routing::Router.new.preview(
      RoutingSpecHelper.request("plan", explicit_intent: RoutingIntent::Plan),
      policy,
      [fallback]
    )

    decision.target.should eq(fallback)
    decision.fallback_used?.should be_true
    decision.eligible_targets.should eq([fallback])
  end

  it "forces required restricted context onto an available local fallback" do
    remote = RoutingSpecHelper.target("openai", "remote")
    local = RoutingSpecHelper.target("local", "fallback", false)
    policy = RoutingSpecHelper.policy(default_target: remote, default_fallbacks: [local])
    request = RoutingSpecHelper.request(
      "review attached policy",
      context: [
        RoutingSpecHelper.context(
          "policy",
          RoutingContextKind::ExplicitlyAttached,
          4,
          restricted: true,
          required: true
        ),
      ]
    )

    decision = Chronicle::Routing::Router.new.preview(request, policy, [remote, local])

    decision.target.should eq(local)
    decision.fallback_used?.should be_true
    decision.included_context.map(&.id).should eq(["policy"])
  end

  it "rejects required context that exceeds the token budget" do
    local = RoutingSpecHelper.target("local", "model", false)
    policy = RoutingSpecHelper.policy(default_target: local, token_budget: 3)
    request = RoutingSpecHelper.request(
      "read attached policy",
      context: [
        RoutingSpecHelper.context(
          "policy",
          RoutingContextKind::ExplicitlyAttached,
          4,
          required: true
        ),
      ]
    )

    expect_raises(Chronicle::ContextBudgetError, "required context exceeds token budget") do
      Chronicle::Routing::Router.new.preview(request, policy, [local])
    end
  end

  it "does not let a remote explicit override bypass required restricted context" do
    remote = RoutingSpecHelper.target("openai", "remote")
    local = RoutingSpecHelper.target("local", "fallback", false)
    policy = RoutingSpecHelper.policy(default_target: remote, default_fallbacks: [local])
    request = RoutingSpecHelper.request(
      "review attached policy",
      explicit_target: remote,
      context: [
        RoutingSpecHelper.context(
          "policy",
          RoutingContextKind::ExplicitlyAttached,
          4,
          restricted: true,
          required: true
        ),
      ]
    )

    expect_raises(Chronicle::NoLocalTargetError, "no eligible local target") do
      Chronicle::Routing::Router.new.preview(request, policy, [remote, local])
    end
  end

  it "keeps a matched local_only rule's whole chain local (remote fallback foreclosed)" do
    remote = RoutingSpecHelper.target("anthropic", "claude-sonnet")
    rule = Chronicle::Routing::RouteRule.new(
      "secrets stay local",
      remote,
      local_only: true,
      fallbacks: [remote],
    )
    policy = RoutingSpecHelper.policy(routing_rules: [rule])

    expect_raises(Chronicle::NoLocalTargetError, "no eligible local target") do
      Chronicle::Routing::Router.new.preview(
        RoutingSpecHelper.request("handle secrets", explicit_intent: RoutingIntent::Plan),
        policy,
        [remote],
      )
    end
  end

  it "routes a matched local_only rule to an available local fallback over a remote primary" do
    remote = RoutingSpecHelper.target("openai", "primary")
    local = RoutingSpecHelper.target("local", "fallback", false)
    rule = Chronicle::Routing::RouteRule.new(
      "sensitive edits",
      remote,
      priority: 10,
      intent: RoutingIntent::Edit,
      fallbacks: [local],
      local_only: true,
    )
    policy = RoutingSpecHelper.policy(routing_rules: [rule])

    decision = Chronicle::Routing::Router.new.preview(
      RoutingSpecHelper.request("edit secrets", explicit_intent: RoutingIntent::Edit),
      policy,
      [remote, local],
    )

    decision.target.should eq(local)
    decision.fallback_used?.should be_true
    decision.eligible_targets.should eq([local])
  end

  it "routes a matched local_only rule to its local primary" do
    local = RoutingSpecHelper.target("local", "llama3", false)
    rule = Chronicle::Routing::RouteRule.new(
      "local only planning",
      local,
      priority: 10,
      intent: RoutingIntent::Plan,
      local_only: true,
    )
    policy = RoutingSpecHelper.policy(routing_rules: [rule])

    decision = Chronicle::Routing::Router.new.preview(
      RoutingSpecHelper.request("plan", explicit_intent: RoutingIntent::Plan),
      policy,
      [local],
    )

    decision.target.should eq(local)
    decision.fallback_used?.should be_false
  end

  it "lets an explicit override bypass a matched local_only rule" do
    remote = RoutingSpecHelper.target("openai", "remote")
    local = RoutingSpecHelper.target("local", "fallback", false)
    rule = Chronicle::Routing::RouteRule.new(
      "local only planning",
      local,
      priority: 10,
      intent: RoutingIntent::Plan,
      fallbacks: [remote],
      local_only: true,
    )
    policy = RoutingSpecHelper.policy(routing_rules: [rule])

    decision = Chronicle::Routing::Router.new.preview(
      RoutingSpecHelper.request("plan", explicit_intent: RoutingIntent::Plan, explicit_target: remote),
      policy,
      [remote, local],
    )

    decision.target.should eq(remote)
    decision.override_used?.should be_true
  end

  it "rejects a route when no primary or fallback target is available" do
    target = RoutingSpecHelper.target("openai", "missing")
    policy = RoutingSpecHelper.policy(default_target: target)

    expect_raises(Chronicle::NoRouteError, "no eligible target") do
      Chronicle::Routing::Router.new.preview(
        RoutingSpecHelper.request("hello"),
        policy,
        [] of Chronicle::Routing::Target
      )
    end
  end

  it "matches paths with glob patterns" do
    rule = Chronicle::Routing::RouteRule.new(
      "multi-glob",
      RoutingSpecHelper.target("openai", "m"),
      priority: 10,
      paths: ["src/crypto/**", "src/auth/**"],
    )
    rule.matches?(RoutingIntent::Chat, ["src/crypto/aes.cr"]).should be_true
    rule.matches?(RoutingIntent::Chat, ["src/auth/login.cr"]).should be_true
    rule.matches?(RoutingIntent::Chat, ["src/main.cr"]).should be_false
    rule.matches?(RoutingIntent::Chat, ["docs/readme.md"]).should be_false
  end

  it "honors local_only and cost_limit fields" do
    rule = Chronicle::Routing::RouteRule.new(
      "expensive local",
      RoutingSpecHelper.target("local", "m", false),
      priority: 5,
      local_only: true,
      cost_limit: 0.50,
    )
    rule.local_only?.should be_true
    rule.cost_limit.should eq(0.50)
  end

  it "loads a Policy from JSON matching the smista config format" do
    json = %({
      "routing_rules": [
        {
          "name": "review crypto",
          "priority": 10,
          "intent": "Review",
          "paths": ["src/crypto/**"],
          "target": { "provider": "openai", "model": "gpt-5", "remote": true, "input_token_cost": 0.001, "output_token_cost": 0.002 }
        }
      ],
      "default_target": { "provider": "local", "model": "fallback", "remote": false, "input_token_cost": 0.0, "output_token_cost": 0.0 },
      "token_budget": 100000
    })

    policy = Chronicle::Routing::Policy.from_json(json)
    policy.routing_rules.size.should eq(1)
    policy.routing_rules.first.name.should eq("review crypto")
    policy.routing_rules.first.paths.should eq(["src/crypto/**"])
    policy.default_target.provider.should eq("local")
    policy.token_budget.should eq(100000)
  end

  it "loads a Policy with the default route (no rules matched)" do
    policy = Chronicle::Routing::Policy.new(
      default_target: RoutingSpecHelper.target("openai", "gpt-5.5-mini"),
      default_fallbacks: [RoutingSpecHelper.target("ollama", "qwen")],
    )
    policy.default_target.model.should eq("gpt-5.5-mini")
    policy.default_fallbacks.size.should eq(1)
    policy.routing_rules.should be_empty
  end

  it "deserializes a RouteRule with local_only and cost_limit from JSON" do
    json = %({
      "name": "expensive local",
      "target": { "provider": "local", "model": "m", "remote": false, "input_token_cost": 0.0, "output_token_cost": 0.0 },
      "local_only": true,
      "cost_limit": 0.50
    })
    rule = Chronicle::Routing::RouteRule.from_json(json)
    rule.local_only?.should be_true
    rule.cost_limit.should eq(0.50)
    rule.name.should eq("expensive local")
  end

  it "loads a Policy from YAML" do
    yaml = <<-YAML
    routing_rules:
      - name: review crypto
        priority: 10
        intent: Review
        paths:
          - src/crypto/**
        target:
          provider: openai
          model: gpt-5
          remote: true
          input_token_cost: 0.001
          output_token_cost: 0.002
    default_target:
      provider: local
      model: fallback
      remote: false
      input_token_cost: 0.0
      output_token_cost: 0.0
    token_budget: 100000
    YAML

    policy = Chronicle::Routing::Config.from_yaml(yaml)
    policy.routing_rules.size.should eq(1)
    policy.routing_rules.first.name.should eq("review crypto")
    policy.routing_rules.first.paths.should eq(["src/crypto/**"])
    policy.default_target.provider.should eq("local")
  end

  describe "ModelCapabilities" do
    it "defaults to no capabilities" do
      caps = Chronicle::Routing::ModelCapabilities.new
      caps.supports?("tools").should be_false
    end

    it "reports supported capability" do
      caps = Chronicle::Routing::ModelCapabilities.new(tools: true)
      caps.supports?("tools").should be_true
      caps.supports?("reasoning").should be_false
    end

    it "lists supported capabilities in declaration order" do
      caps = Chronicle::Routing::ModelCapabilities.new(streaming: true, tools: true, reasoning: true)
      caps.supported.should eq(["streaming", "tools", "reasoning"])
    end

    it "excludes route when target lacks required capabilities" do
      rule = Chronicle::Routing::RouteRule.new(
        "needs tools",
        RoutingSpecHelper.target("local", "m", false),
        priority: 10,
        intent: RoutingIntent::Edit,
        requires_capabilities: Chronicle::Routing::ModelCapabilities.new(tools: true, reasoning: true),
      )
      policy = RoutingSpecHelper.policy(
        routing_rules: [rule],
        default_target: RoutingSpecHelper.target("openai", "fallback"),
      )

      # Target has no capabilities → rule doesn't match → falls to default
      decision = Chronicle::Routing::Router.new.preview(
        RoutingSpecHelper.request("edit", explicit_intent: RoutingIntent::Edit),
        policy,
        [rule.target, policy.default_target],
      )
      decision.matched_rule.should eq("default")
    end

    it "matches rule when target satisfies required capabilities" do
      caps_target = Chronicle::Routing::Target.new(
        "local", "capable-model", false,
        capabilities: Chronicle::Routing::ModelCapabilities.new(tools: true),
      )
      rule = Chronicle::Routing::RouteRule.new(
        "capable rule",
        caps_target,
        priority: 10,
        intent: RoutingIntent::Edit,
        requires_capabilities: Chronicle::Routing::ModelCapabilities.new(tools: true),
      )
      policy = RoutingSpecHelper.policy(routing_rules: [rule])

      decision = Chronicle::Routing::Router.new.preview(
        RoutingSpecHelper.request("edit", explicit_intent: RoutingIntent::Edit),
        policy,
        [caps_target],
      )
      decision.matched_rule.should eq("capable rule")
    end
  end

  it "loads a Policy from a YAML file" do
    path = "/tmp/_clarity_routing_test.yml"
    File.write(path, <<-YAML)
    default_target:
      provider: local
      model: default
      remote: false
      input_token_cost: 0.0
      output_token_cost: 0.0
    token_budget: 50000
    YAML

    policy = Chronicle::Routing::Config.from_file(path)
    policy.default_target.model.should eq("default")
    policy.token_budget.should eq(50000)
    File.delete(path)
  end

  describe "Effort" do
    it "defaults to Medium on RouteRule" do
      rule = Chronicle::Routing::RouteRule.new("test", RoutingSpecHelper.target("local", "m", false))
      rule.effort.should eq(Chronicle::Routing::Effort::Medium)
    end

    it "parses from JSON" do
      json = %({
        "name": "effort test",
        "target": { "provider": "local", "model": "m", "remote": false, "input_token_cost": 0.0, "output_token_cost": 0.0 },
        "effort": "Low"
      })
      rule = Chronicle::Routing::RouteRule.from_json(json)
      rule.effort.should eq(Chronicle::Routing::Effort::Low)
    end

    it "serializes effort in routing reason" do
      rule = Chronicle::Routing::RouteRule.new(
        "high effort", RoutingSpecHelper.target("openai", "m"),
        priority: 10, intent: RoutingIntent::Edit,
        effort: Chronicle::Routing::Effort::High,
      )
      rule.effort.should eq(Chronicle::Routing::Effort::High)
    end
  end

  describe "ClassificationRule" do
    it "matches keywords with typo tolerance (Levenshtein ≤ 1)" do
      rule = Chronicle::Routing::ClassificationRule.new("review", RoutingIntent::Review, 10, ["review"])

      rule.matches?(RoutingSpecHelper.request("review this")).should be_true
      rule.matches?(RoutingSpecHelper.request("revuew this")).should be_true
      rule.matches?(RoutingSpecHelper.request("revue this")).should be_false
    end

    it "includes confidence on the result" do
      policy = RoutingSpecHelper.policy(
        classification_rules: [
          Chronicle::Routing::ClassificationRule.new("review", RoutingIntent::Review, 10, ["review", "audit"]),
          Chronicle::Routing::ClassificationRule.new("edit", RoutingIntent::Edit, 20, ["fix", "change"]),
        ]
      )
      request = RoutingSpecHelper.request("review and audit this")
      decision = Chronicle::Routing::Router.new.preview(request, policy, [policy.default_target])

      decision.classification.confidence.should be > 0
    end
  end

  it "rejects a rule that widens a default permission" do
    target = RoutingSpecHelper.target("openai", "remote")
    rule = Chronicle::Routing::RouteRule.new(
      "unsafe",
      target,
      priority: 10,
      intent: RoutingIntent::Edit,
      required_permissions: {"shell" => RoutingPermissionMode::Allow},
    )
    policy = RoutingSpecHelper.policy(
      routing_rules: [rule],
      default_permissions: {"shell" => RoutingPermissionMode::Deny}
    )

    expect_raises(Chronicle::InvalidRoutingPolicyError, "cannot widen permission") do
      Chronicle::Routing::Router.new.preview(
        RoutingSpecHelper.request("edit", explicit_intent: RoutingIntent::Edit),
        policy,
        [target]
      )
    end
  end
end
