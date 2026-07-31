module Chronicle
  # Agent harness runtime — orchestrates the event loop, budget, and
  # LogAgent execution. Ported from activegraph.runtime.runtime.Runtime.
  class Runtime(M)
    getter store : EventStore
    getter log_agent : LogAgent(M)
    getter run_id : String
    @decision : Routing::RouteDecision?
    @execution_targets = [] of Routing::Target
    @execution_target_index = 0
    @approvals : ApprovalAdapter = ApprovalAdapter.new
    @authority_ceiling : String? = nil
    @loaded_packs : Array(Pack) = [] of Pack
    @frame_stack : FrameStack = FrameStack.new

    # Action-class authority scale, lowest to highest.
    AUTHORITY_RANKS = {"read" => 0, "write" => 1, "admin" => 2, "root" => 3}

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
      @run_id : String = "default",
      @model_effect_worker : ModelEffectWorker? = nil,
      @llm_cache : LLMCache? = nil,
      @strict_expected_hashes : Array(String)? = nil,
      @tools : Array(Tool) = [] of Tool,
      @tool_cache : ToolCache? = nil,
    )
    end

    # Run a prompt through the harness.
    # 1. Creates a goal.created event
    # 2. Routes (if policy provided)
    # 3. Drives the LogAgent through the model/tool loop
    # 4. Records all events to the store
    @response_text : String = ""

    def run(prompt : String, caused_by : String? = nil, max_steps : Int32? = nil) : String
      # Emit goal.created
      goal_event = Event.new(
        schema_version: 1_u16, sequence: next_seq, id: "goal_created_#{next_seq}",
        type: "goal.created", actor: "user", caused_by: caused_by,
        timestamp: Time.utc, payload: JSON.build do |json|
        json.object { json.field "goal", prompt }
      end,
      )
      @store.append(goal_event)
      user_message = record_chat_message("user", prompt, goal_event.id)
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
        @execution_targets = decision.eligible_targets
        @execution_target_index = 0
        record_routing_decision(decision, user_message.id)
      end

      # Drive LogAgent
      msg = Crig::Completion::Message.user(prompt)
      @log_agent.start(msg)

      drive_loop(user_message, max_steps)
      @response_text
    end

    # Run the loop for at most `steps` iterations (a bounded quantum).
    def run_quantum(prompt : String, steps : Int32, caused_by : String? = nil) : String
      run(prompt, caused_by: caused_by, max_steps: steps)
    end

    # Run the loop until the agent reaches a done step.
    def run_until_idle(prompt : String, caused_by : String? = nil) : String
      run(prompt, caused_by: caused_by)
    end

    # Events still available under the budget.
    def budget_remaining : Int64
      @budget.max_events - @store.count
    end

    def start_budget(max_events : Int64) : self
      @budget = Budget.new(max_events: max_events)
      self
    end

    def get_tool(name : String) : Tool?
      @tools.find { |tool| tool.name == name }
    end

    def load_pack(pack : Pack, settings : JSON::Any = JSON::Any.new({} of String => JSON::Any)) : self
      pack.tools.each do |pack_tool|
        @tools << pack_tool unless @tools.any? { |existing| existing.name == pack_tool.name }
      end
      @loaded_packs << pack
      append_event("pack.loaded", JSON.build do |json|
        json.object do
          json.field "pack", pack.name
          json.field "version", pack.version
          json.field "settings" do
            json.raw(settings.to_json)
          end
        end
      end)
      self
    end

    def loaded_packs : Array(String)
      @loaded_packs.map(&.name)
    end

    def pack_policies : Array(Policy)
      @loaded_packs.flat_map(&.policies)
    end

    def tool_requires_approval?(tool_name : String) : Bool
      pack_policies.any?(&.requires_approval.includes?(tool_name))
    end

    def current_frame_id : String?
      @frame_stack.current.try(&.id)
    end

    def push_frame(frame : Frame) : self
      @frame_stack.push(frame)
      self
    end

    def pop_frame : Frame
      @frame_stack.pop
    end

    def events_in_frame(frame_id : String) : Array(Event)
      @store.iter_events.select { |event| event.frame_id == frame_id }
    end

    def add_pending_approval(request : ApprovalRequest) : Nil
      @approvals.request(request)
    end

    def pending_approvals : Array(ApprovalRequest)
      @approvals.pending_requests
    end

    def approve(request_id : String) : ApprovalResult
      @approvals.resolve(ApprovalDecision.new(request_id, approved: true))
    end

    def authority_ceiling : String?
      @authority_ceiling
    end

    # ameba:disable Naming/AccessorMethodName
    def set_authority_ceiling(level : String) : self
      @authority_ceiling = level
      self
    end

    def evaluate_capability_authority(level : String) : Bool
      ceiling = @authority_ceiling
      return true if ceiling.nil?

      (AUTHORITY_RANKS[level]? || -1) <= (AUTHORITY_RANKS[ceiling]? || -1)
    end

    def export_trace : String
      JSON.build do |json|
        json.object do
          json.field "run_id", @run_id
          json.field "events" do
            json.array do
              @store.iter_events.each do |event|
                json.raw(event.canonical_json)
              end
            end
          end
        end
      end
    end

    def status : Hash(String, JSON::Any)
      {
        "run_id"           => JSON::Any.new(@run_id),
        "events"           => JSON::Any.new(@store.count),
        "budget_remaining" => JSON::Any.new(budget_remaining),
        "response"         => JSON::Any.new(@response_text),
      }
    end

    private def drive_loop(user_message : Event, max_steps : Int32?) : Nil
      steps = 0
      loop do
        if budget_exhausted?
          record_budget_exhausted
          break
        end
        if max_steps && steps >= max_steps
          break
        end
        steps += 1
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
          record_chat_message("assistant", @response_text, user_message.id)
          break
        end
      end
    end

    # Accept a channel command exactly once, then execute its durable goal.
    def handle(command : Channel::SendMessage) : Channel::Acknowledgement
      if accepted = accepted_command(command)
        return Channel::Acknowledgement.new(command.command_id, accepted.id, duplicate: true)
      end

      accepted = record_command_accepted(command)
      run(command.content, caused_by: accepted.id)
      Channel::Acknowledgement.new(command.command_id, accepted.id)
    end

    # Load a Runtime from an EventStore with recorded events.
    def self.load(
      store : EventStore,
      log_agent : LogAgent(M),
      policy : Routing::Policy? = nil,
      budget : Budget = Budget.new,
      replay_llm_cache : Bool = false,
      replay_strict : Bool = false,
      tools : Array(Tool) = [] of Tool,
      replay_tool_cache : Bool = false,
    ) : self
      cache = replay_llm_cache ? LLMCache.from_events(store.iter_events) : nil
      tool_cache = replay_tool_cache ? ToolCache.from_events(store.iter_events) : nil
      strict_hashes = if replay_strict
                        store.iter_events.select { |e| e.type == "llm.requested" }.map do |e|
                          JSON.parse(e.payload).as_h["request_hash"]?.try(&.as_s) || ""
                        end
                      end
      new(
        store: store, log_agent: log_agent, policy: policy, budget: budget,
        llm_cache: cache, strict_expected_hashes: strict_hashes,
        tools: tools, tool_cache: tool_cache,
      )
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

    private def accepted_command(command : Channel::SendMessage) : Event?
      @store.iter_events.find do |event|
        next false unless event.type == "command.accepted"

        payload = JSON.parse(event.payload).as_h
        payload["command_id"]?.try(&.as_s?) == command.command_id &&
          payload["run_id"]?.try(&.as_s?) == command.run_id
      end
    end

    private def record_command_accepted(command : Channel::SendMessage) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "command_accepted_#{next_seq}",
        type: "command.accepted",
        actor: "channel.#{command.channel}",
        caused_by: nil,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "command_id", command.command_id
            json.field "run_id", command.run_id
            json.field "channel", command.channel
            json.field "intent_hint", command.intent_hint
            json.field "model_override", command.model_override
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_routing_decision(decision : Routing::RouteDecision, caused_by : String) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "routing_decided_#{next_seq}",
        type: "routing.decided",
        actor: "runtime",
        caused_by: caused_by,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "intent", decision.intent.to_s
            json.field "classification" do
              json.object do
                json.field "matched_rule", decision.classification.matched_rule
                json.field "explicit", decision.classification.explicit?
                json.field "confidence", decision.classification.confidence
              end
            end
            json.field "provider", decision.target.provider
            json.field "model", decision.target.model
            json.field "eligible_targets" do
              json.array do
                decision.eligible_targets.each do |target|
                  json.object do
                    json.field "provider", target.provider
                    json.field "model", target.model
                  end
                end
              end
            end
            json.field "matched_rule", decision.matched_rule
            json.field "reason", decision.routing_reason
            json.field "override_used", decision.override_used?
            json.field "fallback_used", decision.fallback_used?
            json.field "included_context" do
              json.array { decision.included_context.each { |context| json.string(context.id) } }
            end
            json.field "excluded_context" do
              json.array do
                decision.excluded_context.each do |context|
                  json.object do
                    json.field "id", context.id
                    json.field "reason", context.reason
                  end
                end
              end
            end
            json.field "required_permissions" do
              json.object do
                decision.required_permissions.each do |name, permission|
                  json.field name, permission.to_s
                end
              end
            end
            json.field "estimated_cost" do
              json.object do
                json.field "minimum", decision.estimated_cost.minimum
                json.field "maximum", decision.estimated_cost.maximum
              end
            end
          end
        end,
      )
      @store.append(event)
      event
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

    private def record_chat_message(role : String, content : String, caused_by : String?) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "chat_message_#{next_seq}",
        type: "chat.message",
        actor: role == "user" ? "user" : "agent",
        caused_by: caused_by,
        frame_id: current_frame_id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "role", role
            json.field "content", content
          end
        end,
      )
      @store.append(event)
      event
    end

    private def drive_model(step : Crig::AgentRunStep) : Nil
      return if budget_exhausted?
      effect = @log_agent.record_model_effect(step)
      return unless effect
      return if budget_exhausted?

      prompt = step.prompt
      history = step.history
      raise "model step is missing its prompt or history" unless prompt && history

      request = @log_agent.agent.build_completion_request(prompt, history).build
      response = execute_model_request(effect, request)
      turn = Crig::ModelTurn.new(
        message_id: "msg_#{next_seq}",
        choice: response.choice,
        usage: response.usage,
        allowed_tools: @tools.map(&.name),
      )
      @log_agent.model_response(turn, result_hash: effect.content_hash)
    end

    private def execute_model_request(
      effect : EffectRequest,
      request : Crig::Completion::Request::CompletionRequest,
    )
      loop do
        target = current_execution_target || Routing::Target.new("legacy", "default", false)
        cached = @llm_cache.try(&.get(effect.content_hash))
        if hashes = @strict_expected_hashes
          assert_prompt_hash!(hashes, effect.content_hash)
        end
        request_event = record_llm_requested(effect, target, cache_hit: !cached.nil?)

        if cached_result = cached
          response = completion_response_from_cache(cached_result)
          record_llm_responded(request_event, target, response)
          return response
        end

        begin
          result = edge_worker.execute(ModelEffectInvocation.new(ModelEffectRequest.new(request_event.id, effect, target), request))
          response = Crig::Completion::CompletionResponse(String).new(
            result.choice,
            Crig::Completion::Usage.new(input_tokens: result.input_tokens, output_tokens: result.output_tokens),
            "",
            result.message_id,
          )
          record_llm_responded(request_event, target, response)
          @llm_cache.try(&.record(effect.content_hash, EffectResult.new(effect.content_hash, true, response_cache_payload(response))))
          return response
        rescue ex : Exception
          failed_event = record_llm_failed(request_event, target, ex)
          if ex.is_a?(RetryableProviderError)
            if select_next_fallback(failed_event)
              next
            else
              record_fallback_exhausted(failed_event)
            end
          end
          raise ex
        end
      end
    end

    private def assert_prompt_hash!(expected_hashes : Array(String), actual : String) : Nil
      expected = expected_hashes.shift? || ""
      if expected != actual
        raise ReplayDivergenceError.new(
          "replay diverged on prompt hash: expected prompt_hash=#{expected}, got prompt_hash=#{actual}"
        )
      end
    end

    private def completion_response_from_cache(result : EffectResult) : Crig::Completion::CompletionResponse(String)
      payload = JSON.parse(result.payload).as_h
      content = payload["content"]?.try(&.as_s) || ""
      input = payload["input_tokens"]?.try(&.as_i) || 0
      output = payload["output_tokens"]?.try(&.as_i) || 0
      choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(content)
      )
      Crig::Completion::CompletionResponse(String).new(
        choice,
        Crig::Completion::Usage.new(input_tokens: input, output_tokens: output),
        "",
        payload["message_id"]?.try(&.as_s) || "cached",
      )
    end

    private def response_cache_payload(response) : String
      JSON.build do |json|
        json.object do
          json.field "content", response.choice.first.text.try(&.text)
          json.field "input_tokens", response.usage.input_tokens
          json.field "output_tokens", response.usage.output_tokens
          json.field "message_id", response.message_id
        end
      end
    end

    private def current_execution_target : Routing::Target?
      @execution_targets[@execution_target_index]? || @decision.try(&.target)
    end

    private def edge_worker : ModelEffectWorker
      if worker = @model_effect_worker
        return worker
      end
      ModelEffectWorker.new(FixedModelExecutor(M).new(@log_agent.agent.model))
    end

    private def select_next_fallback(caused_by : Event) : Bool
      next_index = @execution_target_index + 1
      target = @execution_targets[next_index]?
      return false unless target

      @execution_target_index = next_index
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "routing_fallback_selected_#{next_seq}",
        type: "routing.fallback_selected",
        actor: "runtime",
        caused_by: caused_by.id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "provider", target.provider
            json.field "model", target.model
          end
        end,
      )
      @store.append(event)
      true
    end

    private def record_fallback_exhausted(caused_by : Event) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "routing_fallback_exhausted_#{next_seq}",
        type: "routing.fallback_exhausted",
        actor: "runtime",
        caused_by: caused_by.id,
        timestamp: Time.utc,
        payload: %({"reason":"no recorded eligible fallback remains"}),
      )
      @store.append(event)
      event
    end

    private def record_llm_requested(
      effect : EffectRequest,
      target : Routing::Target?,
      cache_hit : Bool = false,
    ) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "llm_requested_#{next_seq}",
        type: "llm.requested",
        actor: "runtime",
        caused_by: nil,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "request_hash", effect.content_hash
            json.field "provider", target.try(&.provider)
            json.field "model", target.try(&.model)
            json.field "cache_hit", cache_hit
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_llm_responded(
      request_event : Event,
      target : Routing::Target?,
      response,
    ) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "llm_responded_#{next_seq}",
        type: "llm.responded",
        actor: "provider",
        caused_by: request_event.id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "input_tokens", response.usage.input_tokens
            json.field "output_tokens", response.usage.output_tokens
            json.field "message_id", response.message_id
            json.field "provider", target.try(&.provider)
            json.field "model", target.try(&.model)
            json.field "content", response.choice.first.text.try(&.text)
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_llm_failed(
      request_event : Event,
      target : Routing::Target?,
      error : Exception,
    ) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "llm_failed_#{next_seq}",
        type: "llm.failed",
        actor: "provider",
        caused_by: request_event.id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "error_class", error.class.to_s
            json.field "reason", safe_provider_failure_reason(error)
            json.field "retryable", error.is_a?(RetryableProviderError)
            json.field "provider", target.try(&.provider)
            json.field "model", target.try(&.model)
          end
        end,
      )
      @store.append(event)
      event
    end

    private def safe_provider_failure_reason(error : Exception) : String
      return "provider unavailable" if error.is_a?(ProviderNotAvailableError)
      "provider execution failed"
    end

    private def drive_tools(step : Crig::AgentRunStep) : Nil
      calls = step.calls
      return unless calls

      results = calls.map do |call|
        tc = call.tool_call
        name = tc.function.name
        args = tc.function.arguments.to_json
        output = invoke_tool(name, args)
        Crig::Completion::UserContent.tool_result(
          tc.id,
          Crig::OneOrMany(Crig::Completion::ToolResultContent).one(
            Crig::Completion::ToolResultContent.text(output)
          )
        )
      end
      @log_agent.tool_results(results)
    end

    private def invoke_tool(name : String, args : String) : String
      request_event = record_tool_requested(name, args)
      if cached = @tool_cache.try(&.get(name, args))
        record_tool_responded(request_event, name, args, cached)
        return cached
      end
      if tool_requires_approval?(name)
        add_pending_approval(ApprovalRequest.new("approval_#{next_seq}", ApprovalKind::Shell, "tool #{name}"))
        placeholder = %({"pending_approval":true,"tool":"#{name}"})
        record_tool_responded(request_event, name, args, placeholder)
        return placeholder
      end
      tool = @tools.find { |registered| registered.name == name }
      raise GraphProjectionError.new("unknown tool: #{name}") unless tool
      output = tool.call(args)
      record_tool_responded(request_event, name, args, output)
      @tool_cache.try(&.record(name, args, output))
      output
    end

    private def append_event(type : String, payload : String) : Event
      event = Event.new(
        schema_version: 1_u16, sequence: next_seq,
        id: "#{type.gsub(".", "_")}_#{next_seq}",
        type: type, actor: "runtime", caused_by: nil,
        frame_id: current_frame_id,
        timestamp: Time.utc, payload: payload,
      )
      @store.append(event)
      event
    end

    private def record_tool_requested(name : String, args : String) : Event
      event = Event.new(
        schema_version: 1_u16, sequence: next_seq,
        id: "tool_requested_#{next_seq}", type: "tool.requested",
        actor: "runtime", caused_by: nil, timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "tool", name
            json.field "args" do
              json.raw(args)
            end
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_tool_responded(request_event : Event, name : String, args : String, output : String) : Event
      event = Event.new(
        schema_version: 1_u16, sequence: next_seq,
        id: "tool_responded_#{next_seq}", type: "tool.responded",
        actor: "tool", caused_by: request_event.id, timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "tool", name
            json.field "args" do
              json.raw(args)
            end
            json.field "output" do
              json.raw(output)
            end
          end
        end,
      )
      @store.append(event)
      event
    end
  end
end
