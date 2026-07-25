require "crig"

module Clarity
  class LogAgent(M)
    getter agent : Crig::Agent(M)

    @run : Crig::AgentRun?

    def initialize(@agent : Crig::Agent(M))
    end

    def start(prompt : Crig::Completion::Message) : self
      @run = Crig::AgentRun.new(prompt)
      self
    end

    def next_step : Crig::AgentRunStep
      run = @run
      raise "LogAgent not started; call #start" unless run
      run.next_step
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

    def model_response(turn : Crig::ModelTurn) : Nil
      run = @run
      raise "LogAgent not started; call #start" unless run
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
  end
end
