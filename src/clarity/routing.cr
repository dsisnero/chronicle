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

    struct Target
      getter provider : String
      getter model : String
      getter? remote : Bool
      getter input_token_cost : Float64
      getter output_token_cost : Float64

      def initialize(
        @provider : String,
        @model : String,
        @remote : Bool,
        @input_token_cost : Float64,
        @output_token_cost : Float64,
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

    struct ClassificationRule
      getter name : String
      getter intent : Intent
      getter priority : Int32
      getter keywords : Array(String)
      getter requires_any_context : Array(ContextKind)

      def initialize(
        @name : String,
        @intent : Intent,
        @priority : Int32,
        @keywords : Array(String),
        @requires_any_context : Array(ContextKind) = [] of ContextKind,
      )
      end

      def matches?(request : Request) : Bool
        text_matches = @keywords.empty? || @keywords.any? do |keyword|
          request.text.downcase.includes?(keyword.downcase)
        end
        context_matches = @requires_any_context.empty? || request.context.any? do |candidate|
          @requires_any_context.includes?(candidate.kind)
        end

        text_matches && context_matches
      end
    end

    struct RouteRule
      getter name : String
      getter priority : Int32
      getter intent : Intent?
      getter path_prefix : String?
      getter target : Target
      getter fallbacks : Array(Target)
      getter required_permissions : Hash(String, PermissionMode)

      def initialize(
        @name : String,
        @priority : Int32,
        @intent : Intent?,
        @path_prefix : String?,
        @target : Target,
        @fallbacks : Array(Target) = [] of Target,
        @required_permissions : Hash(String, PermissionMode) = {} of String => PermissionMode,
      )
      end

      def matches?(intent : Intent, paths : Array(String)) : Bool
        intent_matches = @intent.nil? || @intent == intent
        path_matches = if path_prefix = @path_prefix
                         paths.any?(&.starts_with?(path_prefix))
                       else
                         true
                       end
        intent_matches && path_matches
      end

      def specificity : Int32
        return 3 if @intent && @path_prefix
        return 2 if @path_prefix
        return 1 if @intent

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
        @classification_rules : Array(ClassificationRule),
        @routing_rules : Array(RouteRule),
        @default_target : Target,
        @default_fallbacks : Array(Target),
        @token_budget : Int32,
        @default_permissions : Hash(String, PermissionMode),
      )
        raise InvalidRoutingPolicyError.new("token budget must not be negative") if @token_budget < 0
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

      def initialize(@intent : Intent, @matched_rule : String?, @explicit : Bool)
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
          return Classification.new(intent, nil, true)
        end

        matches = [] of {ClassificationRule, Int32}
        policy.classification_rules.each_with_index do |rule, index|
          matches << {rule, index} if rule.matches?(request)
        end
        return Classification.new(Intent::Chat, nil, false) if matches.empty?

        winner = matches.min_by { |entry| {entry[0].priority, entry[1]} }[0]
        Classification.new(winner.intent, winner.name, false)
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
