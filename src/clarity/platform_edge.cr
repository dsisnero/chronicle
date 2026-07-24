require "cml"

module Clarity
  enum PlatformSignalKind
    SocketBytes
    EffectResult
    Approval
    Cancellation
    Timeout
  end

  struct PlatformSignal
    getter kind : PlatformSignalKind
    getter payload : String

    def initialize(@kind : PlatformSignalKind, @payload : String)
    end
  end

  struct IngressEnvelope
    getter sequence : UInt64
    getter kind : PlatformSignalKind
    getter payload : String

    def initialize(@sequence : UInt64, @kind : PlatformSignalKind, @payload : String)
    end
  end

  # The only component allowed to assign ingress order before core conversion.
  class PlatformSequencer
    @next_sequence = 1_u64

    def ingest(signal : PlatformSignal) : IngressEnvelope
      envelope = IngressEnvelope.new(@next_sequence, signal.kind, signal.payload)
      @next_sequence += 1
      envelope
    end
  end

  # CML owns concurrent edge waits; it never leaks CML values into the core.
  class CMLPlatformEdge
    getter socket_channel : CML::Chan(PlatformSignal)
    getter effect_channel : CML::Chan(PlatformSignal)
    getter approval_channel : CML::Chan(PlatformSignal)
    getter cancellation_channel : CML::Chan(PlatformSignal)
    getter timeout_channel : CML::Chan(PlatformSignal)

    def initialize
      @socket_channel = CML::Chan(PlatformSignal).new
      @effect_channel = CML::Chan(PlatformSignal).new
      @approval_channel = CML::Chan(PlatformSignal).new
      @cancellation_channel = CML::Chan(PlatformSignal).new
      @timeout_channel = CML::Chan(PlatformSignal).new
    end

    def next_signal_event : CML::Event(PlatformSignal)
      CML.choose(
        @socket_channel.recv_evt,
        @effect_channel.recv_evt,
        @approval_channel.recv_evt,
        @cancellation_channel.recv_evt,
        @timeout_channel.recv_evt
      )
    end

    def next_ingress_event(sequencer : PlatformSequencer) : CML::Event(IngressEnvelope)
      CML.wrap(next_signal_event) { |signal| sequencer.ingest(signal) }
    end
  end
end
