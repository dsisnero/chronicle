require "../spec_helper"

def make_test_log(path : String, event_count : Int32 = 3)
  log = Chronicle::EventLog.new
  (1..event_count).each do |i|
    log.append(Chronicle::Event.new(
      schema_version: 1_u16, sequence: i.to_u64,
      id: "evt_#{i.to_s.rjust(6, '0')}",
      type: "goal.created", actor: "user", caused_by: i > 1 ? "evt_#{(i - 1).to_s.rjust(6, '0')}" : nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"goal":"step #{i}"}),
    ))
  end
  encoded = Chronicle::EventLogCodec.encode(log)
  File.write(path, encoded)
end

describe "fork CLI" do
  it "forks an event log at a given sequence and saves the result" do
    src = "/tmp/_clarity_fork_src.log"
    dst = "/tmp/_clarity_fork_dst.log"
    make_test_log(src, 5)

    output = Chronicle::CLI.run(["fork", "--from", src, "--at", "3", "--out", dst])

    output.should contain("Forked at sequence 3")
    File.exists?(dst).should be_true

    forked = Chronicle::EventLogCodec.decode(File.read(dst))
    forked.events.size.should eq(3)
    forked.events.last.sequence.should eq(3)

    File.delete(src)
    File.delete(dst)
  end

  it "forks at a sequence beyond the log returns all events" do
    src = "/tmp/_clarity_fork_past.log"
    make_test_log(src, 3)

    output = Chronicle::CLI.run(["fork", "--from", src, "--at", "99", "--out", "/tmp/_clarity_fork_past_out.log"])

    output.should contain("3 events")

    File.delete(src)
  end
end
