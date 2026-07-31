require "../spec_helper"

describe Chronicle::PlatformSequencer do
  it "turns edge signals into monotonically sequenced ingress envelopes" do
    sequencer = Chronicle::PlatformSequencer.new

    socket = sequencer.ingest(Chronicle::PlatformSignal.new(Chronicle::PlatformSignalKind::SocketBytes, "GET /"))
    effect = sequencer.ingest(Chronicle::PlatformSignal.new(Chronicle::PlatformSignalKind::EffectResult, "{}"))

    socket.sequence.should eq(1_u64)
    socket.kind.should eq(Chronicle::PlatformSignalKind::SocketBytes)
    effect.sequence.should eq(2_u64)
  end

  it "composes CML edge channels into one synchronizable signal event" do
    edge = Chronicle::CMLPlatformEdge.new
    signal = Chronicle::PlatformSignal.new(Chronicle::PlatformSignalKind::Approval, "approved")

    spawn { CML.sync(edge.approval_channel.send_evt(signal)) }
    received = CML.sync(edge.next_signal_event)

    received.should eq(signal)
  end

  it "wraps a selected CML signal into a sequenced ingress envelope" do
    edge = Chronicle::CMLPlatformEdge.new
    sequencer = Chronicle::PlatformSequencer.new
    signal = Chronicle::PlatformSignal.new(Chronicle::PlatformSignalKind::Cancellation, "cancelled")

    spawn { CML.sync(edge.cancellation_channel.send_evt(signal)) }
    ingress = CML.sync(edge.next_ingress_event(sequencer))

    ingress.sequence.should eq(1_u64)
    ingress.kind.should eq(Chronicle::PlatformSignalKind::Cancellation)
  end
end
