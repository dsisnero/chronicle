require "../spec_helper"

describe Clarity::PlatformSequencer do
  it "turns edge signals into monotonically sequenced ingress envelopes" do
    sequencer = Clarity::PlatformSequencer.new

    socket = sequencer.ingest(Clarity::PlatformSignal.new(Clarity::PlatformSignalKind::SocketBytes, "GET /"))
    effect = sequencer.ingest(Clarity::PlatformSignal.new(Clarity::PlatformSignalKind::EffectResult, "{}"))

    socket.sequence.should eq(1_u64)
    socket.kind.should eq(Clarity::PlatformSignalKind::SocketBytes)
    effect.sequence.should eq(2_u64)
  end

  it "composes CML edge channels into one synchronizable signal event" do
    edge = Clarity::CMLPlatformEdge.new
    signal = Clarity::PlatformSignal.new(Clarity::PlatformSignalKind::Approval, "approved")

    spawn { CML.sync(edge.approval_channel.send_evt(signal)) }
    received = CML.sync(edge.next_signal_event)

    received.should eq(signal)
  end

  it "wraps a selected CML signal into a sequenced ingress envelope" do
    edge = Clarity::CMLPlatformEdge.new
    sequencer = Clarity::PlatformSequencer.new
    signal = Clarity::PlatformSignal.new(Clarity::PlatformSignalKind::Cancellation, "cancelled")

    spawn { CML.sync(edge.cancellation_channel.send_evt(signal)) }
    ingress = CML.sync(edge.next_ingress_event(sequencer))

    ingress.sequence.should eq(1_u64)
    ingress.kind.should eq(Clarity::PlatformSignalKind::Cancellation)
  end
end
