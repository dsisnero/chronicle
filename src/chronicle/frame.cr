module Chronicle
  # Mission context for a run: the goal plus its guardrails.
  # Ported from activegraph.frame.Frame.
  struct Frame
    @@_frame_counter : UInt64 = 0_u64

    getter id : String
    getter goal : String
    getter constraints : Array(String)
    getter success_criteria : Array(String)
    getter permissions : Array(String)

    def initialize(
      @goal : String,
      @id : String = self.class.next_id,
      @constraints : Array(String) = [] of String,
      @success_criteria : Array(String) = [] of String,
      @permissions : Array(String) = [] of String,
    )
    end

    def self.next_id : String
      @@_frame_counter += 1
      "frame_#{@@_frame_counter}"
    end
  end

  # LIFO stack of active frames. The runtime pushes a frame when entering
  # a sub-context and pops it when the sub-context completes.
  class FrameStack
    def initialize
      @frames = [] of Frame
    end

    def push(frame : Frame) : Nil
      @frames << frame
    end

    def pop : Frame
      @frames.pop
    end

    def current : Frame?
      @frames.last?
    end

    def size : Int32
      @frames.size
    end
  end
end
