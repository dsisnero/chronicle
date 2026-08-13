require "../spec_helper"

private def approval_event(
  id : String,
  type : String,
  sequence : UInt64,
  approval_id : String,
  object_type : String = "risky",
  data : String = %({"action":"wipe"}),
  reason : String = "test",
  pack : String = "",
) : Chronicle::Event
  payload = if type == "approval.proposed"
              JSON.build do |j|
                j.object do
                  j.field "approval_id", approval_id
                  j.field "object_type", object_type
                  j.field "data" do
                    j.raw(data)
                  end
                  j.field "reason", reason
                  j.field "pack", pack
                end
              end
            else
              %({"approval_id":"#{approval_id}"})
            end
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: sequence, id: id,
    type: type, actor: "runtime", caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

describe Chronicle::RuntimeReason do
  it "rebuilds pending approvals as proposed minus granted (upstream _rebuild_pending_approvals)" do
    events = [
      approval_event("evt_propose_1", "approval.proposed", 1_u64, "approval_001"),
      approval_event("evt_propose_2", "approval.proposed", 2_u64, "approval_002", object_type: "other"),
      approval_event("evt_grant_1", "approval.granted", 3_u64, "approval_001"),
    ]
    result = Chronicle::RuntimeReason.rebuild_pending_approvals(events)
    result[:pending].map(&.id).should eq(["approval_002"])
    result[:pending][0].object_type.should eq("other")
    result[:pending][0].data.should eq(%({"action":"wipe"}))
    result[:next_approval_n].should eq(3)
  end

  it "keeps proposal order and full payload data" do
    events = [
      approval_event("evt_propose_1", "approval.proposed", 1_u64, "approval_007"),
      approval_event("evt_propose_2", "approval.proposed", 2_u64, "approval_008"),
    ]
    result = Chronicle::RuntimeReason.rebuild_pending_approvals(events)
    result[:pending].map(&.id).should eq(["approval_007", "approval_008"])
    result[:pending][0].reason.should eq("test")
    result[:pending][0].data.should eq(%({"action":"wipe"}))
    result[:next_approval_n].should eq(9)
  end

  it "advances the id counter past recorded ids even with no pending approvals" do
    events = [
      approval_event("evt_propose_1", "approval.proposed", 1_u64, "approval_004"),
      approval_event("evt_grant_1", "approval.granted", 2_u64, "approval_004"),
    ]
    result = Chronicle::RuntimeReason.rebuild_pending_approvals(events)
    result[:pending].should be_empty
    result[:next_approval_n].should eq(5)
  end

  it "skips proposed events without a data payload but still advances the counter" do
    old_event = approval_event("evt_propose_1", "approval.proposed", 1_u64, "approval_003")
    payload = JSON.parse(old_event.payload).as_h
    payload.delete("data")
    evt = Chronicle::Event.new(
      schema_version: old_event.schema_version, sequence: old_event.sequence,
      id: old_event.id, type: old_event.type, actor: old_event.actor,
      caused_by: old_event.caused_by, timestamp: old_event.timestamp,
      payload: payload.to_json,
    )
    result = Chronicle::RuntimeReason.rebuild_pending_approvals([evt])
    result[:pending].should be_empty
    result[:next_approval_n].should eq(4)
  end

  it "is empty with no counter advance for an empty log" do
    result = Chronicle::RuntimeReason.rebuild_pending_approvals([] of Chronicle::Event)
    result[:pending].should be_empty
    result[:next_approval_n].should eq(1)
  end

  it "ignores non-approval events" do
    goal = Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: "evt_goal",
      type: "goal.created", actor: "user", caused_by: nil,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: %({"goal":"go"}),
    )
    result = Chronicle::RuntimeReason.rebuild_pending_approvals([goal])
    result[:pending].should be_empty
    result[:next_approval_n].should eq(1)
  end
end

private def gated_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_approval_#{tag}_#{Random::Secure.hex(4)}.db")
end

module ApprovalReloadPack
  include Chronicle::Packs::DSL

  @[ObjectType(name: "risky")]
  struct Risky
    include JSON::Serializable

    getter action : String
  end

  @[Behavior(name: "proposer", on: ["goal.created"])]
  def proposer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    ctx.propose_object("risky", %({"action":"wipe"}), reason: "test")
  end

  pack(
    name: "approvalreload",
    version: "0.1.0",
    policies: [
      Chronicle::Packs::PackPolicy.new(name: "gate_risky", requires_approval: ["risky"]),
    ],
  )
end

private def approval_gated_runtime(tag : String) : {String, Chronicle::Runtime(PackModel)}
  db = gated_db_path(tag)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "run_#{tag}")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
  rt.load_pack(ApprovalReloadPack::PACK)
  {db, rt}
end

describe Chronicle::Runtime do
  it "pending approvals survive reload and approve after load" do
    db, rt = approval_gated_runtime("reload")
    rt.run_goal("go")
    rt.pack_pending_approvals.size.should eq(1)
    approval_id = rt.pack_pending_approvals.first.id

    loaded = Chronicle::Runtime(PackModel).load(
      db, rt.run_id, Crig::Agent(PackModel).new(model: PackModel.new, preamble: ""), max_turns: 1
    )
    pending = loaded.pack_pending_approvals
    pending.map(&.id).should eq([approval_id])
    pending.first.object_type.should eq("risky")
    JSON.parse(pending.first.data)["action"].as_s.should eq("wipe")

    materialized = loaded.approve_pack(approval_id)
    loaded.graph.not_nil!.get_object(materialized.id).not_nil!.data.should contain(%("action"))
  end

  it "granted approvals do not reappear after load and fresh ids avoid collision" do
    db, rt = approval_gated_runtime("granted")
    rt.run_goal("go")
    approval_id = rt.pack_pending_approvals.first.id
    rt.approve_pack(approval_id)

    loaded = Chronicle::Runtime(PackModel).load(
      db, rt.run_id, Crig::Agent(PackModel).new(model: PackModel.new, preamble: ""), max_turns: 1
    )
    loaded.pack_pending_approvals.should be_empty

    new_id = loaded.propose_object("risky", %({"action":"again"}), reason: "test")
    new_id.should_not eq(approval_id)
  end

  it "a fork inherits pending approvals" do
    db, rt = approval_gated_runtime("fork")
    rt.run_goal("go")
    approval_id = rt.pack_pending_approvals.first.id

    fork = rt.fork(at_event: rt.store.iter_events.last.id)
    fork.pack_pending_approvals.map(&.id).should eq([approval_id])
  end
end
