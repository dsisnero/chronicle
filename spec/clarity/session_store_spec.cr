require "../spec_helper"

describe Clarity::SessionStore do
  it "saves an event log to a file and loads it back" do
    store = Clarity::SessionStore.new("/tmp/_clarity_sessions_test")
    log = Clarity::EventLog.new
    log.append(Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
      type: "goal.created", actor: "user", caused_by: nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"goal":"test"}),
    ))

    path = store.save(log, session_name: "test_session")
    File.exists?(path).should be_true

    loaded = store.load(path)
    loaded.events.size.should eq(1)
    loaded.events.first.id.should eq("evt_001")

    File.delete(path)
  end

  it "lists saved sessions in a directory" do
    dir = "/tmp/_clarity_sessions_list_test"
    store = Clarity::SessionStore.new(dir)
    log = Clarity::EventLog.new
    log.append(Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
      type: "goal.created", actor: "user", caused_by: nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"goal":"test"}),
    ))

    path1 = store.save(log, session_name: "session_a")
    path2 = store.save(log, session_name: "session_b")

    sessions = store.list
    sessions.size.should be >= 2
    sessions.any?(&.includes?("session_a")).should be_true
    sessions.any?(&.includes?("session_b")).should be_true

    File.delete(path1)
    File.delete(path2)
  end

  it "creates the session directory if it doesn't exist" do
    dir = "/tmp/_clarity_sessions_create_test"
    store = Clarity::SessionStore.new(dir)
    Dir.exists?(dir).should be_true

    log = Clarity::EventLog.new
    log.append(Clarity::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
      type: "goal.created", actor: "user", caused_by: nil,
      timestamp: Time.utc(2026, 7, 25, 12, 0, 0),
      payload: %({"goal":"test"}),
    ))

    path = store.save(log, session_name: "create_test")
    File.exists?(path).should be_true
    File.delete(path)
    Dir.delete(dir)
  end
end
