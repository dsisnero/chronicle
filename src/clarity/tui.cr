module Clarity
  # Terminal UI for the Clarity agent harness using Bubble Tea.
  module TUI
    enum State
      Input
      Processing
      Done
    end

    struct Message
      getter role : String
      getter content : String
      getter tool_name : String?

      def initialize(@role : String, @content : String, @tool_name : String? = nil)
      end
    end

    struct PendingApproval
      getter tool_name : String
      getter args : String

      def initialize(@tool_name : String, @args : String)
      end
    end

    struct Model
      getter state : State
      getter messages : Array(Message)
      getter pending_approval : PendingApproval?

      def initialize(
        @state : State = State::Input,
        @messages : Array(Message) = [] of Message,
        @pending_approval : PendingApproval? = nil,
      )
      end

      def handle_input(text : String) : Model
        msg = Message.new(role: "user", content: text)
        Model.new(state: State::Processing, messages: @messages + [msg])
      end

      def handle_response(text : String) : Model
        msg = Message.new(role: "assistant", content: text)
        Model.new(state: State::Input, messages: @messages + [msg])
      end

      def handle_tool_call(tool_name : String, args : String, requires_approval : Bool = false) : Model
        msg = Message.new(role: "tool_call", content: args, tool_name: tool_name)
        if requires_approval
          Model.new(
            state: State::Processing,
            messages: @messages + [msg],
            pending_approval: PendingApproval.new(tool_name: tool_name, args: args),
          )
        else
          Model.new(messages: @messages + [msg])
        end
      end

      def approve_pending : Model
        pa = @pending_approval
        return self unless pa
        msg = Message.new(role: "approval", content: "Approved: #{pa.tool_name}")
        Model.new(state: State::Processing, messages: @messages + [msg])
      end

      def reject_pending : Model
        pa = @pending_approval
        return self unless pa
        msg = Message.new(role: "rejection", content: "Rejected: #{pa.tool_name}")
        Model.new(state: State::Input, messages: @messages + [msg])
      end

      def render : String
        lines = [] of String
        lines << "Clarity Agent"
        lines << "=" * 40
        @messages.each do |msg|
          case msg.role
          when "user"
            lines << ""
            lines << ">>> #{msg.content}"
          when "assistant"
            lines << ""
            lines << msg.content
          when "tool_call"
            lines << ""
            lines << "  [Tool: #{msg.tool_name}] #{msg.content}"
          when "approval"
            lines << ""
            lines << "  ✓ #{msg.content}"
          when "rejection"
            lines << ""
            lines << "  ✗ #{msg.content}"
          end
        end
        if pa = @pending_approval
          lines << ""
          lines << "  ? Approve #{pa.tool_name}? (y/n)"
        end
        if @state.input?
          lines << ""
          lines << "> "
        end
        lines.join("\n")
      end
    end
  end
end
