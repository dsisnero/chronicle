require "bubbletea"

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
        end
        lines.join("\n")
      end
    end

    # Bubble Tea program model — wraps the core Model with key handling.
    class Program
      getter state : State
      getter messages : Array(Message)
      getter pending_approval : PendingApproval?
      getter input_buffer : String

      @core : Model

      def initialize
        @core = Model.new
        @state = @core.state
        @messages = @core.messages
        @pending_approval = @core.pending_approval
        @input_buffer = ""
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
        @input_buffer += char.to_s
        self
      end

      def handle_backspace : Program
        return self if @state.done?
        @input_buffer = @input_buffer.rchop
        self
      end

      def handle_enter : Program
        return self if @state.done?
        text = @input_buffer
        @input_buffer = ""
        @core = @core.handle_input(text)
        sync
        self
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
        if @state.input? && !@input_buffer.empty?
          text += @input_buffer
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

      def initialize
        @program = Program.new
      end

      def init : Tea::Cmd?
        nil
      end

      def update(msg : Tea::Msg) : Nil
        case msg
        when Tea::KeyPressMsg
          if msg.code == Tea::KeyEnter
            @program = @program.handle_enter
          elsif msg.code == Tea::KeyBackspace
            @program = @program.handle_backspace
          elsif msg.code == 3 || msg.text == "\\x03"
            @program = @program.handle_quit
          elsif msg.printable?
            msg.text.each_char { |char| @program = @program.handle_key(char) }
          end
        end
      end

      def view : Tea::View
        Clarity::TUI.disabled_view(@program.render)
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

      def initialize(@runtime : Runtime(M))
        super()
      end

      def update(msg : Tea::Msg) : Nil
        case msg
        when Tea::KeyPressMsg
          if msg.code == Tea::KeyEnter
            text = @program.input_buffer
            @program = @program.handle_enter
            response = @runtime.run(text)
            @program = @program.handle_response(response)
          elsif msg.code == Tea::KeyBackspace
            @program = @program.handle_backspace
          elsif msg.code == 3 || msg.text == "\\x03"
            @program = @program.handle_quit
          elsif msg.printable?
            msg.text.each_char { |char| @program = @program.handle_key(char) }
          end
        end
      end
    end

    # Run the TUI interactively without a Runtime.
    def self.run
      run_bubbletea(StandaloneBubbleTeaModel.new)
    end

    # Run the TUI with a Runtime for agent execution.
    def self.run_with(runtime : Runtime(M)) forall M
      run_bubbletea(BubbleTeaModel(M).new(runtime))
    end

    private def self.run_bubbletea(model : Tea::Model)
      program = Tea::Program.new(model)
      program.run
      nil
    rescue ex
      puts "TUI error: #{ex.message}"
      puts "Falling back to simple input mode..."
      simple_loop
    end

    # Simple readline-based fallback when TUI is unavailable.
    private def self.simple_loop
      puts "Clarity Agent (simple mode — type /quit to exit)"
      loop do
        print "> "
        input = gets
        break unless input
        text = input.strip
        break if text == "/quit"
        puts ">>> #{text}"
        puts "(model execution not available in simple mode)"
      end
    end
  end
end
