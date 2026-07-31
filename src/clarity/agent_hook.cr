require "crig"
require "json"

# Agent hook that records the agent loop's model/tool activity into the event
# store through crig's hook dispatch — the supported extension surface for
# customizing how the AgentRunner works. Ported from activegraph's
# tool.requested / tool.responded / llm.requested recording.
module Clarity
  class AgentHook
    include Crig::AgentHook

    @store : EventStore?
    @tool_cache : ToolCache?

    def initialize(
      @store : EventStore? = nil,
      @tool_cache : ToolCache? = nil,
      @run_id : String = "default",
    )
    end

    def on_completion_call(ctx : Crig::HookContext, event : Crig::StepEvent) : Crig::CompletionCallAction
      record("llm.requested", JSON.build do |json|
        json.object do
          json.field "prompt", event.prompt_text
          json.field "turn", event.turn
        end
      end)
      Crig::CompletionCallAction.cont
    end

    def on_tool_call(ctx : Crig::HookContext, event : Crig::StepEvent) : Crig::ToolCallAction
      name = event.tool_name || ""
      args = event.args || ""
      record("tool.requested", JSON.build do |json|
        json.object do
          json.field "tool", name
          json.field "args" do
            json.raw(args)
          end
        end
      end)
      Crig::ToolCallAction.cont
    end

    def on_tool_result(ctx : Crig::HookContext, event : Crig::StepEvent) : Crig::ToolResultAction
      name = event.tool_name || ""
      args = event.args || ""
      result = event.result || ""
      @tool_cache.try(&.record(name, args, result))
      record("tool.responded", JSON.build do |json|
        json.object do
          json.field "tool", name
          json.field "args" do
            json.raw(args)
          end
          json.field "output" do
            json.raw(result)
          end
        end
      end)
      Crig::ToolResultAction.cont
    end

    def on_event(ctx : Crig::HookContext, event : Crig::StepEvent) : Crig::Flow
      Crig::Flow.cont
    end

    private def record(type : String, payload : String) : Nil
      store = @store
      return unless store

      sequence = (store.count + 1).to_u64
      store.append(Event.new(
        schema_version: 1_u16, sequence: sequence,
        id: "#{type.gsub(".", "_")}_#{sequence}",
        type: type, actor: "agent.hook", caused_by: nil,
        timestamp: Time.utc, payload: payload,
      ))
    end
  end
end
