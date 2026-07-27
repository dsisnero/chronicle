require "bubbletea"
require "bubbles"

module Clarity
  # Terminal UI for the Clarity agent harness.
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

    # Projects durable chat turns into the presentation model. The event log is
    # authoritative; this is only a current, renderable view of it.
    module Transcript
      def self.project(events : Enumerable(Event)) : Array(Message)
        events.each_with_object([] of Message) do |event, messages|
          next unless event.type == "chat.message"

          payload = JSON.parse(event.payload).as_h
          role = payload["role"]?.try(&.as_s?)
          content = payload["content"]?.try(&.as_s?)
          next unless role && content

          messages << Message.new(role, content)
        end
      end
    end

    struct PendingApproval
      getter tool_name : String
      getter args : String

      def initialize(@tool_name : String, @args : String)
      end
    end

    struct RuntimeResponseMsg
      include Tea::Msg

      getter content : String

      def initialize(@content : String)
      end
    end

    # Core state machine model (testable without Bubble Tea).
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
            lines << "  \u{2713} #{msg.content}"
          when "rejection"
            lines << ""
            lines << "  \u{2717} #{msg.content}"
          end
        end
        if pa = @pending_approval
          lines << ""
          lines << "  ? Approve #{pa.tool_name}? (y/n)"
        end
        if @state.input?
          lines << ""
          lines << "> "
        elsif @state.processing?
          lines << ""
          lines << "  Thinking…"
        end
        lines.join("\n")
      end
    end

    # Bubble Tea program model — wraps the core Model with key handling.
    class Program
      getter state : State
      getter messages : Array(Message)
      getter pending_approval : PendingApproval?
      getter input : Bubbles::TextInput::Model

      @core : Model

      def initialize(messages : Array(Message) = [] of Message)
        @core = Model.new(messages: messages)
        @state = @core.state
        @messages = @core.messages
        @pending_approval = @core.pending_approval
        @input = Bubbles::TextInput::Model.new
        @input.prompt = "> "
        @input.placeholder = "Ask Clarity…"
        @input.width = 72
        @input.virtual_cursor = false
        @input.focus
      end

      def self.from_events(events : Enumerable(Event)) : Program
        new(Transcript.project(events))
      end

      def input_buffer : String
        @input.value
      end

      def handle_key(char : Char) : Program
        return self if @state.done?
        if @pending_approval
          if char == 'y'
            @core = @core.approve_pending
          elsif char == 'n'
            @core = @core.reject_pending
          end
          sync
          return self
        end
        @input.value = @input.value + char
        self
      end

      def handle_backspace : Program
        return self if @state.done?
        @input.value = @input.value.rchop
        self
      end

      def handle_enter : Program
        return self if @state.done?
        text = @input.value
        @input.reset
        @core = @core.handle_input(text)
        sync
        self
      end

      def update_input(msg : Tea::Msg) : Tea::Cmd?
        @input, cmd = @input.update(msg)
        cmd
      end

      def handle_response(text : String) : Program
        @core = @core.handle_response(text)
        sync
        self
      end

      def handle_tool_call(tool_name : String, args : String, requires_approval : Bool = false) : Program
        @core = @core.handle_tool_call(tool_name, args, requires_approval: requires_approval)
        sync
        self
      end

      def handle_quit : Program
        @state = State::Done
        self
      end

      def render : String
        text = @core.render
        if @state.input?
          text = text[0...-2] if text.ends_with?("> ")
          text += @input.view
        end
        text
      end

      private def sync
        @state = @core.state
        @messages = @core.messages
        @pending_approval = @core.pending_approval
      end
    end

    # Bubble Tea model that implements Tea::Model interface.
    # Wraps Program and Runtime, handles Tea messages (key presses).
    # Non-generic base Bubble Tea model (standalone, no runtime).
    class StandaloneBubbleTeaModel
      include Tea::Model

      getter program : Program

      def input : Bubbles::TextInput::Model
        @program.input
      end

      def initialize
        @program = Program.new
      end

      def init : Tea::Cmd?
        nil
      end

      def update(msg : Tea::Msg) : Tuple(Tea::Model, Tea::Cmd?)
        cmd = nil
        case msg
        when Tea::KeyPressMsg
          if msg.code == Tea::KeyEnter
            @program = @program.handle_enter
          elsif msg.keystroke == "ctrl+c" || msg.code == 3 || msg.text == "\u0003"
            @program = @program.handle_quit
            cmd = Tea.quit
          else
            cmd = @program.update_input(msg)
          end
        end
        {self, cmd}
      end

      def view : Tea::View
        content = @program.render
        view = Clarity::TUI.disabled_view(content)
        if cursor = @program.input.cursor
          cursor.y = content.count('\n')
          view.cursor = cursor
        end
        view
      end
    end

    def self.disabled_view(content : String) : Tea::View
      view = Tea::View.new(content)
      view.keyboard_enhancements = Tea::KeyboardEnhancements.new
      view.mouse_mode = Tea::MouseMode::None
      view
    end

    # Generic Bubble Tea model with a Runtime for actual agent execution.
    class BubbleTeaModel(M) < StandaloneBubbleTeaModel
      getter runtime : Runtime(M)
      @command_sequence : UInt64

      def initialize(@runtime : Runtime(M))
        super()
        @program = Program.from_events(@runtime.store.iter_events)
        @command_sequence = @runtime.store.iter_events.count { |event| event.type == "command.accepted" && event.actor == "channel.tui" }.to_u64
      end

      def update(msg : Tea::Msg) : Tuple(Tea::Model, Tea::Cmd?)
        cmd = nil
        case msg
        when RuntimeResponseMsg
          @program = @program.handle_response(msg.content)
        when Tea::KeyPressMsg
          if msg.code == Tea::KeyEnter
            text = @program.input.value
            @program = @program.handle_enter
            command = Channel::SendMessage.new(
              command_id: next_command_id,
              run_id: @runtime.run_id,
              content: text,
              channel: "tui",
            )
            cmd = -> : Tea::Msg? {
              begin
                @runtime.handle(command)
                RuntimeResponseMsg.new(@runtime.response)
              rescue ex
                RuntimeResponseMsg.new("Error: #{ex.message}")
              end
            }
          elsif msg.keystroke == "ctrl+c" || msg.code == 3 || msg.text == "\u0003"
            @program = @program.handle_quit
            cmd = Tea.quit
          else
            cmd = @program.update_input(msg)
          end
        end
        {self, cmd}
      end

      private def next_command_id : String
        @command_sequence += 1_u64
        "tui_#{@command_sequence}"
      end
    end

    # Run the TUI interactively without a Runtime.
    def self.run
      model = StandaloneBubbleTeaModel.new
      run_program(model)
    end

    # Run the TUI with a Runtime for agent execution.
    def self.run_with(runtime : Runtime(M)) forall M
      model = BubbleTeaModel(M).new(runtime)
      run_program(model)
    end

    private def self.run_program(model : Tea::Model)
      program = Tea::Program.new(model)
      _model, error = program.run
      raise error if error
      nil
    end
  end
end
