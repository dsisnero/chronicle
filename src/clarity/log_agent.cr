require "crig"

module Clarity
  class LogAgent(M)
    getter agent : Crig::Agent(M)
    getter store : EventStore?

    @run : Crig::AgentRun?
    @sequence : UInt64
    @goals_created : Int32

    def initialize(@agent : Crig::Agent(M), store : EventStore? = nil)
      @store = store
      @sequence = 0_u64
      @goals_created = 0
    end

    def start(prompt : Crig::Completion::Message) : self
      @run = Crig::AgentRun.new(prompt)
      @goals_created += 1
      record_event("goal.created", %({"goal":"#{prompt.rag_text || ""}"}))
      self
    end

    def next_step : Crig::AgentRunStep
      run = @run
      raise "LogAgent not started; call #start" unless run
      run.next_step
    end

    # Record an effect.requested event for a model call step.
    # Returns the original EffectRequest for the caller to execute.
    def record_model_effect(step : Crig::AgentRunStep) : EffectRequest?
      effect = model_effect(step)
      return nil unless effect

      record_event("effect.requested", %({"hash":"#{effect.content_hash}","kind":"model"}))
      effect
    end

    # Record an effect.requested event for each tool call in the step.
    # Returns the array of EffectRequests for the caller to execute.
    def record_tool_effects(step : Crig::AgentRunStep) : Array(EffectRequest)
      effects = tool_effects(step)
      effects.each do |effect|
        record_event("effect.requested", %({"hash":"#{effect.content_hash}","kind":"tool"}))
      end
      effects
    end

    def model_effect(step : Crig::AgentRunStep) : EffectRequest?
      return nil unless prompt = step.prompt

      preamble = agent.preamble
      payload = JSON.build do |json|
        json.object do
          json.field "turn", step.turn
          json.field "preamble", preamble
          json.field "prompt_text", prompt.rag_text
        end
      end
      EffectRequest.new("model_turn_#{step.turn}", EffectKind::Model, payload)
    end

    def model_response(turn : Crig::ModelTurn, result_hash : String? = nil) : Nil
      run = @run
      raise "LogAgent not started; call #start" unless run
      if hash = result_hash
        response_payload = JSON.build do |json|
          json.object do
            json.field "hash", hash
            json.field "success", true
            json.field "output_tokens", turn.usage.output_tokens
            json.field "input_tokens", turn.usage.input_tokens
          end
        end
        record_event("effect.responded", response_payload)
      end
      run.model_response(turn)
    end

    def tool_results(results : Array(Crig::Completion::UserContent)) : Nil
      run = @run
      raise "LogAgent not started; call #start" unless run
      run.tool_results(results)
    end

    def tool_effects(step : Crig::AgentRunStep) : Array(EffectRequest)
      return [] of EffectRequest unless calls = step.calls
      calls.map do |call|
        tc = call.tool_call
        payload = JSON.build do |json|
          json.object do
            json.field "tool", tc.function.name
            json.field "call_id", tc.call_id
            json.field "id", tc.id
            json.field "arguments", tc.function.arguments.to_json
          end
        end
        EffectRequest.new("tool_#{tc.id}", EffectKind::Tool, payload)
      end
    end

    private def record_event(type : String, payload : String) : Nil
      return unless s = @store

      @sequence += 1
      event = Event.new(
        schema_version: 1_u16,
        sequence: @sequence,
        id: "#{type.gsub(".", "_")}_#{@sequence}",
        type: type,
        actor: "agent",
        caused_by: nil,
        timestamp: Time.utc,
        payload: payload,
      )
      s.append(event)
    end
  end
end
