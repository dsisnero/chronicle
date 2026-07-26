module Clarity
  # Agent harness runtime — orchestrates the event loop, budget, and
  # LogAgent execution. Ported from activegraph.runtime.runtime.Runtime.
  class Runtime(M)
    getter store : EventStore
    getter log_agent : LogAgent(M)
    @decision : Routing::RouteDecision?

    # Budget limits for a run.
    struct Budget
      getter max_events : Int64

      def initialize(@max_events : Int64 = 1000)
      end
    end

    def initialize(
      @store : EventStore,
      @log_agent : LogAgent(M),
      @policy : Routing::Policy? = nil,
      @budget : Budget = Budget.new,
      @available_targets : Array(Routing::Target) = [] of Routing::Target,
    )
    end

    # Run a prompt through the harness.
    # 1. Creates a goal.created event
    # 2. Routes (if policy provided)
    # 3. Drives the LogAgent through the model/tool loop
    # 4. Records all events to the store
    @response_text : String = ""

    def run(prompt : String) : String
      # Emit goal.created
      goal_event = Event.new(
        schema_version: 1_u16, sequence: next_seq, id: "goal_created",
        type: "goal.created", actor: "user", caused_by: nil,
        timestamp: Time.utc, payload: %({"goal":"#{prompt}"}),
      )
      @store.append(goal_event)
      return @response_text if budget_exhausted?

      # Route if we have a policy
      if policy = @policy
        targets = @available_targets
        if targets.empty?
          targets = policy.configured_targets
        end
        request = Routing::Request.new(
          prompt, nil, nil, [] of String,
          [] of Routing::ContextCandidate, nil, 50,
        )
        decision = Routing::Router.new.preview(request, policy, targets)
        @decision = decision
      end

      # Drive LogAgent
      msg = Crig::Completion::Message.user(prompt)
      @log_agent.start(msg)

      loop do
        if budget_exhausted?
          record_budget_exhausted
          break
        end
        step = @log_agent.next_step
        case step.kind
        in .call_model?
          drive_model(step)
        in .call_tools?
          drive_tools(step)
        in .done?
          if resp = step.response
            @response_text = resp.output
          end
          break
        end
      end
      @response_text
    end

    # Load a Runtime from an EventStore with recorded events.
    def self.load(
      store : EventStore,
      log_agent : LogAgent(M),
      policy : Routing::Policy? = nil,
      budget : Budget = Budget.new,
    ) : self
      new(store: store, log_agent: log_agent, policy: policy, budget: budget)
    end

    def decision : Routing::RouteDecision?
      @decision
    end

    def response : String
      @response_text
    end

    private def next_seq : UInt64
      (@store.count + 1).to_u64
    end

    private def budget_exhausted? : Bool
      @store.count >= @budget.max_events
    end

    private def record_budget_exhausted : Nil
      evt = Event.new(
        schema_version: 1_u16, sequence: next_seq, id: "budget_exhausted",
        type: "budget.exhausted", actor: "runtime", caused_by: nil,
        timestamp: Time.utc, payload: %({"max_events":#{@budget.max_events}}),
      )
      @store.append(evt)
    end

    private def drive_model(step : Crig::AgentRunStep) : Nil
      return if budget_exhausted?
      effect = @log_agent.record_model_effect(step)
      return unless effect
      return if budget_exhausted?

      choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Mock response")
      )
      turn = Crig::ModelTurn.new(
        message_id: "msg_#{next_seq}",
        choice: choice,
        usage: Crig::Completion::Usage.new(input_tokens: 10, output_tokens: 5),
        allowed_tools: [] of String,
      )
      @log_agent.model_response(turn, result_hash: effect.content_hash)
    end

    private def drive_tools(step : Crig::AgentRunStep) : Nil
      effects = @log_agent.record_tool_effects(step)
      results = effects.map do |_effect|
        Crig::Completion::UserContent.tool_result(
          "tc_#{next_seq}",
          Crig::OneOrMany(Crig::Completion::ToolResultContent).one(
            Crig::Completion::ToolResultContent.text("mock tool result")
          )
        )
      end
      @log_agent.tool_results(results)
    end
  end
end
