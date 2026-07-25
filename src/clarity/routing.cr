module Clarity
  # Pure, deterministic policy evaluation for selecting a model and context.
  module Routing
    enum Intent
      Chat
      Plan
      Edit
      Review
      Summarize
      Prompt
      Skill
    end

    enum ContextKind
      ExplicitlyAttached
      GitDiff
      HistoryBuffer
      MemoryFact
    end

    enum PermissionMode
      Allow
      Ask
      Deny
    end

    enum Effort
      Low
      Medium
      High
    end

    enum Confidence
      VeryLow
      Low
      Medium
      High
      VeryHigh
    end

    struct Target
      include JSON::Serializable

      getter provider : String
      getter model : String
      getter? remote : Bool
      getter input_token_cost : Float64
      getter output_token_cost : Float64

      def initialize(
        @provider : String,
        @model : String,
        @remote : Bool = true,
        @input_token_cost : Float64 = 0.001,
        @output_token_cost : Float64 = 0.002,
      )
      end
    end

    struct ContextCandidate
      getter id : String
      getter kind : ContextKind
      getter token_count : Int32
      getter path : String?
      getter? restricted_for_remote : Bool
      getter? required : Bool

      def initialize(
        @id : String,
        @kind : ContextKind,
        @token_count : Int32,
        @path : String?,
        @restricted_for_remote : Bool,
        @required : Bool = false,
      )
      end
    end

    module KeywordMatch
      # Levenshtein distance between two strings, capped at max_dist.
      def self.levenshtein(a : String, b : String, max_dist : Int = 1) : Int
        return 0 if a == b
        return a.size if b.empty?
        return b.size if a.empty?
        return max_dist + 1 if (a.size - b.size).abs > max_dist

        # Keep track of two rows to save memory
        prev = (0..b.size).to_a
        (1..a.size).each do |i|
          curr = [i] of Int32
          (1..b.size).each do |j|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            curr << Math.min(Math.min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
          end
          prev = curr
          return max_dist + 1 if prev.min > max_dist
        end
        prev.last
      end

      # Returns true if text contains any keyword or a close typo (≤ max_dist edits).
      def self.matches_any?(text : String, keywords : Array(String), max_dist : Int = 1) : Bool
        return true if keywords.empty?
        words = text.downcase.split(/\s+/)
        keywords.each do |keyword|
          kw = keyword.downcase
          words.each do |word|
            return true if levenshtein(word, kw, max_dist) <= max_dist
          end
        end
        false
      end
    end

    struct ClassificationRule
      include JSON::Serializable

      getter name : String
      getter intent : Intent
      getter priority : Int32
      getter keywords : Array(String)
      getter requires_any_context : Array(ContextKind)

      def initialize(
        @name : String,
        @intent : Intent,
        @priority : Int32,
        @keywords : Array(String) = [] of String,
        @requires_any_context : Array(ContextKind) = [] of ContextKind,
      )
      end

      def matches?(request : Request) : Bool
        text_matches = KeywordMatch.matches_any?(request.text, @keywords)
        context_matches = @requires_any_context.empty? || request.context.any? do |candidate|
          @requires_any_context.includes?(candidate.kind)
        end
        text_matches && context_matches
      end

      def match_count(text : String) : Int32
        return 0 if @keywords.empty?
        words = text.downcase.split(/\s+/)
        @keywords.count do |keyword|
          words.any? { |word| KeywordMatch.levenshtein(word, keyword.downcase, 1) <= 1 }
        end
      end
    end

    DEFAULT_RULE_PRIORITY = 1000

    struct RouteRule
      getter name : String
      getter priority : Int32
      getter intent : Intent?
      getter paths : Array(String)
      getter target : Target
      getter fallbacks : Array(Target)
      getter required_permissions : Hash(String, PermissionMode)
      getter? local_only : Bool
      getter cost_limit : Float64?
      getter effort : Effort

      def initialize(
        @name : String,
        @target : Target,
        @priority : Int32 = DEFAULT_RULE_PRIORITY,
        @intent : Intent? = nil,
        @paths : Array(String) = [] of String,
        @fallbacks : Array(Target) = [] of Target,
        @required_permissions : Hash(String, PermissionMode) = {} of String => PermissionMode,
        @local_only : Bool = false,
        @cost_limit : Float64? = nil,
        @effort : Effort = Effort::Medium,
      )
      end

      def self.from_json(string_or_io : String | IO) : self
        new(JSON.parse(string_or_io).as_h)
      end

      def self.new(pull : JSON::PullParser) : self
        obj = JSON.parse(pull).as_h
        new(obj)
      end

      private def initialize(obj : Hash(String, JSON::Any))
        @name = obj["name"].as_s
        @priority = obj.fetch("priority", JSON::Any.new(DEFAULT_RULE_PRIORITY)).as_i.to_i32
        @intent = obj["intent"]?.try { |value| Intent.parse(value.as_s) }
        @paths = obj.fetch("paths", JSON::Any.new([] of JSON::Any)).as_a.map(&.as_s)
        @target = Target.from_json(obj["target"].to_json)
        @fallbacks = obj.fetch("fallbacks", JSON::Any.new([] of JSON::Any)).as_a.map { |entry| Target.from_json(entry.to_json) }
        @required_permissions = obj.fetch("required_permissions", JSON::Any.new({} of String => JSON::Any)).as_h.transform_values { |value| PermissionMode.parse(value.as_s) }
        @local_only = obj.fetch("local_only", JSON::Any.new(false)).as_bool
        @cost_limit = obj["cost_limit"]?.try(&.as_f)
        @effort = obj.fetch("effort", JSON::Any.new("Medium")).as_s.try { |value| Effort.parse(value) } || Effort::Medium
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "name", @name
          json.field "priority", @priority
          json.field "intent", @intent.try(&.to_s)
          json.field "paths", @paths
          @target.to_json(json)
          json.field "fallbacks" do
            # ameba:disable Style/VerboseBlock
            json.array { @fallbacks.each { |fallback| fallback.to_json(json) } }
          end
          json.field "required_permissions", @required_permissions
          json.field "local_only", @local_only
          json.field "cost_limit", @cost_limit
        end
      end

      def to_json : String
        io = IO::Memory.new
        to_json(JSON::Builder.new(io))
        io.to_s
      end

      def matches?(intent : Intent, candidate_paths : Array(String)) : Bool
        intent_matches = @intent.nil? || @intent == intent
        path_matches = @paths.empty? || @paths.any? do |glob|
          candidate_paths.any? { |cand_path| File.match?(glob, cand_path) }
        end
        intent_matches && path_matches
      end

      def specificity : Int32
        has_path = !@paths.empty?
        has_intent = !@intent.nil?
        return 3 if has_path && has_intent
        return 2 if has_path
        return 1 if has_intent

        0
      end
    end

    struct Policy
      getter classification_rules : Array(ClassificationRule)
      getter routing_rules : Array(RouteRule)
      getter default_target : Target
      getter default_fallbacks : Array(Target)
      getter token_budget : Int32
      getter default_permissions : Hash(String, PermissionMode)

      def initialize(
        @classification_rules : Array(ClassificationRule) = [] of ClassificationRule,
        @routing_rules : Array(RouteRule) = [] of RouteRule,
        @default_target : Target = Target.new("local", "fallback", false),
        @default_fallbacks : Array(Target) = [] of Target,
        @token_budget : Int32 = 100_000,
        @default_permissions : Hash(String, PermissionMode) = {} of String => PermissionMode,
      )
        raise InvalidRoutingPolicyError.new("token budget must not be negative") if @token_budget < 0
      end

      def self.from_json(string_or_io : String | IO) : self
        obj = JSON.parse(string_or_io).as_h

        classification_rules = obj.fetch("classification_rules", JSON::Any.new([] of JSON::Any)).as_a.map do |rule_node|
          ClassificationRule.from_json(rule_node.to_json)
        end
        routing_rules = obj.fetch("routing_rules", JSON::Any.new([] of JSON::Any)).as_a.map do |rule_node|
          RouteRule.from_json(rule_node.to_json)
        end
        default_target = Target.from_json(obj.fetch("default_target", JSON::Any.new({"provider" => JSON::Any.new("local"), "model" => JSON::Any.new("fallback"), "remote" => JSON::Any.new(false), "input_token_cost" => JSON::Any.new(0.0), "output_token_cost" => JSON::Any.new(0.0)})).to_json)
        default_fallbacks = obj.fetch("default_fallbacks", JSON::Any.new([] of JSON::Any)).as_a.map { |entry| Target.from_json(entry.to_json) }
        token_budget = obj.fetch("token_budget", JSON::Any.new(100_000)).as_i.to_i32
        default_permissions = obj.fetch("default_permissions", JSON::Any.new({} of String => JSON::Any)).as_h.transform_values { |value| PermissionMode.parse(value.as_s) }

        new(classification_rules, routing_rules, default_target, default_fallbacks, token_budget, default_permissions)
      end

      def configured_targets : Array(Target)
        targets = [@default_target] + @default_fallbacks
        @routing_rules.each do |rule|
          targets << rule.target
          targets.concat(rule.fallbacks)
        end
        targets.uniq
      end
    end

    struct Request
      getter text : String
      getter explicit_intent : Intent?
      getter explicit_target : Target?
      getter paths : Array(String)
      getter context : Array(ContextCandidate)
      getter focus_path : String?
      getter estimated_completion_tokens : Int32

      def initialize(
        @text : String,
        @explicit_intent : Intent?,
        @explicit_target : Target?,
        @paths : Array(String),
        @context : Array(ContextCandidate),
        @focus_path : String?,
        @estimated_completion_tokens : Int32,
      )
      end
    end

    struct Classification
      getter intent : Intent
      getter matched_rule : String?
      getter? explicit : Bool
      getter confidence : Float64

      def initialize(@intent : Intent, @matched_rule : String?, @explicit : Bool, @confidence : Float64 = 0.0)
      end
    end

    struct ExcludedContext
      getter id : String
      getter reason : String

      def initialize(@id : String, @reason : String)
      end
    end

    struct CostEstimate
      getter minimum : Float64
      getter maximum : Float64

      def initialize(@minimum : Float64, @maximum : Float64)
      end
    end

    struct RouteDecision
      getter intent : Intent
      getter classification : Classification
      getter target : Target
      getter matched_rule : String
      getter routing_reason : String
      getter? override_used : Bool
      getter? fallback_used : Bool
      getter included_context : Array(ContextCandidate)
      getter excluded_context : Array(ExcludedContext)
      getter required_permissions : Hash(String, PermissionMode)
      getter estimated_cost : CostEstimate

      def initialize(
        @intent : Intent,
        @classification : Classification,
        @target : Target,
        @matched_rule : String,
        @routing_reason : String,
        @override_used : Bool,
        @fallback_used : Bool,
        @included_context : Array(ContextCandidate),
        @excluded_context : Array(ExcludedContext),
        @required_permissions : Hash(String, PermissionMode),
        @estimated_cost : CostEstimate,
      )
      end
    end

    class Router
      def preview(
        request : Request,
        policy : Policy,
        available_targets : Array(Target),
      ) : RouteDecision
        classification = classify(request, policy)
        rule = select_rule(classification.intent, request.paths, policy.routing_rules)
        target, override_used = selected_target(request, policy, rule)
        fallbacks = override_used ? ([] of Target) : (rule.try(&.fallbacks) || policy.default_fallbacks)
        requires_local = request.context.any? { |candidate| candidate.required? && candidate.restricted_for_remote? }
        selected_target, fallback_used = available_target(target, fallbacks, available_targets, requires_local)
        permissions = effective_permissions(policy.default_permissions, rule)
        included, excluded = select_context(request, policy.token_budget, selected_target)
        cost = estimate_cost(included, request.estimated_completion_tokens, selected_target)

        RouteDecision.new(
          classification.intent,
          classification,
          selected_target,
          rule.try(&.name) || "default",
          routing_reason(rule, override_used),
          override_used,
          fallback_used,
          included,
          excluded,
          permissions,
          cost
        )
      end

      private def classify(request : Request, policy : Policy) : Classification
        if intent = request.explicit_intent
          return Classification.new(intent, nil, true, 1.0)
        end

        matches = [] of {ClassificationRule, Int32}
        policy.classification_rules.each_with_index do |rule, index|
          matches << {rule, index} if rule.matches?(request)
        end
        return Classification.new(Intent::Chat, nil, false, 0.0) if matches.empty?

        winner = matches.min_by { |entry| {entry[0].priority, entry[1]} }[0]
        total = winner.keywords.size
        matched = winner.match_count(request.text)
        confidence = total > 0 ? matched.to_f / total.to_f : 0.0
        Classification.new(winner.intent, winner.name, false, confidence)
      end

      private def select_rule(
        intent : Intent,
        paths : Array(String),
        rules : Array(RouteRule),
      ) : RouteRule?
        matches = [] of {RouteRule, Int32}
        rules.each_with_index do |rule, index|
          matches << {rule, index} if rule.matches?(intent, paths)
        end
        return nil if matches.empty?

        matches.min_by { |entry| {entry[0].priority, -entry[0].specificity, entry[1]} }[0]
      end

      private def selected_target(
        request : Request,
        policy : Policy,
        rule : RouteRule?,
      ) : {Target, Bool}
        if target = request.explicit_target
          unless policy.configured_targets.includes?(target)
            raise OverrideNotAllowedError.new("explicit target is not configured")
          end
          return {target, true}
        end

        if selected_rule = rule
          {selected_rule.target, false}
        else
          {policy.default_target, false}
        end
      end

      private def available_target(
        target : Target,
        fallbacks : Array(Target),
        available_targets : Array(Target),
        requires_local : Bool,
      ) : {Target, Bool}
        candidates = [target] + fallbacks
        candidates.each_with_index do |candidate, index|
          if available_targets.includes?(candidate) && (!requires_local || !candidate.remote?)
            return {candidate, index > 0}
          end
        end

        raise NoLocalTargetError.new("no eligible local target") if requires_local
        raise NoRouteError.new("no eligible target")
      end

      private def routing_reason(rule : RouteRule?, override_used : Bool) : String
        return "explicit target override" if override_used
        return "default route" unless rule

        return "default route" unless selected_rule = rule
        "priority=#{selected_rule.priority}, specificity=#{selected_rule.specificity}"
      end

      private def effective_permissions(
        defaults : Hash(String, PermissionMode),
        rule : RouteRule?,
      ) : Hash(String, PermissionMode)
        effective = defaults.dup
        return effective unless selected_rule = rule

        selected_rule.required_permissions.each do |name, mode|
          if default_mode = defaults[name]?
            if permission_rank(mode) < permission_rank(default_mode)
              raise InvalidRoutingPolicyError.new("cannot widen permission #{name}")
            end
          end
          effective[name] = mode
        end
        effective
      end

      private def permission_rank(mode : PermissionMode) : Int32
        case mode
        when .allow? then 0
        when .ask?   then 1
        when .deny?  then 2
        else
          raise InvalidRoutingPolicyError.new("unknown permission mode")
        end
      end

      private def select_context(
        request : Request,
        token_budget : Int32,
        target : Target,
      ) : {Array(ContextCandidate), Array(ExcludedContext)}
        excluded = [] of ExcludedContext
        candidates = [] of ContextCandidate
        request.context.each do |candidate|
          if target.remote? && candidate.restricted_for_remote?
            excluded << ExcludedContext.new(candidate.id, "restricted for remote")
          else
            candidates << candidate
          end
        end

        candidates.sort_by! { |candidate| {-context_score(candidate, request.focus_path), candidate.id} }
        included = [] of ContextCandidate
        required_candidates = candidates.select(&.required?)
        required_tokens = required_candidates.sum(&.token_count)
        if required_tokens > token_budget
          raise ContextBudgetError.new("required context exceeds token budget")
        end

        included.concat(required_candidates)
        remaining = token_budget - required_tokens
        candidates.each do |candidate|
          next if candidate.required?

          if candidate.token_count <= remaining
            included << candidate
            remaining -= candidate.token_count
          else
            excluded << ExcludedContext.new(candidate.id, "token budget exceeded")
          end
        end
        {included, excluded}
      end

      private def context_score(candidate : ContextCandidate, focus_path : String?) : Int32
        score = case candidate.kind
                when .explicitly_attached? then 5000
                when .git_diff?            then 4000
                when .history_buffer?      then 3000
                when .memory_fact?         then 2000
                else                            0
                end
        score += 500 if focus_path && candidate.path == focus_path
        score
      end

      private def estimate_cost(
        context : Array(ContextCandidate),
        completion_tokens : Int32,
        target : Target,
      ) : CostEstimate
        input_tokens = context.sum(&.token_count)
        minimum = input_tokens * target.input_token_cost
        maximum = minimum + completion_tokens * target.output_token_cost
        CostEstimate.new(minimum, maximum)
      end
    end
  end
end
