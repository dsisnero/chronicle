require "../spec_helper"

describe Chronicle::Authority do
  it "exposes the closed class and ceiling sets" do
    Chronicle::Authority::ACTION_CLASSES.should eq(["R0", "R1", "R2", "R3", "R4"])
    Chronicle::Authority::AUTHORITY_CEILINGS.should eq(["none", "R0", "R1", "R2"])
  end

  it "default ceiling of none means nothing auto-approves" do
    {"R0", "R1", "R2"}.each do |cls|
      d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: cls, ceiling: "none")
      d.decision.should eq("require_approval")
      d.matched_policy.should eq("above_ceiling")
    end
  end

  it "routes every closed-set class at ceiling R2" do
    expected = {
      "R0" => "auto_approve",
      "R1" => "auto_approve",
      "R2" => "auto_approve",
      "R3" => "require_approval",
      "R4" => "governance_gate",
    }
    expected.each do |cls, decision|
      d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: cls, ceiling: "R2")
      d.decision.should eq(decision)
    end
  end

  it "fails closed for anything outside the closed class set" do
    {"r0", "R5", "R2 ", "low", "medium", "high", "critical"}.each do |bogus|
      d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: bogus, ceiling: "R2")
      d.decision.should eq("require_approval")
      d.matched_policy.should eq("fail_closed_invalid_action_class")
    end
  end

  it "fails closed for a missing action_class" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: "", ceiling: "R2")
    d.decision.should eq("require_approval")
    d.matched_policy.should eq("fail_closed_missing_action_class")
  end

  it "R3 requires approval under every ceiling" do
    Chronicle::Authority::AUTHORITY_CEILINGS.each do |ceiling|
      d = Chronicle::Authority.evaluate_action_authority(capability: "mail.send", action_class: "R3", ceiling: ceiling)
      d.decision.should eq("require_approval")
      d.matched_policy.should eq("approval_required_r3")
    end
  end

  it "R4 routes to the governance gate under every ceiling" do
    Chronicle::Authority::AUTHORITY_CEILINGS.each do |ceiling|
      d = Chronicle::Authority.evaluate_action_authority(capability: "evolution.adopt_proposal", action_class: "R4", ceiling: ceiling)
      d.decision.should eq("governance_gate")
      d.matched_policy.should eq("governance_gate_r4")
      d.auto_approved.should be_false
    end
  end

  it "R4 stays at the governance gate even under a stray capability ceiling" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: "R4", ceiling: "R2", capability_ceiling: "R2")
    d.decision.should eq("governance_gate")
  end

  it "a stricter capability ceiling lowers the effective ceiling" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: "R1", ceiling: "R2", capability_ceiling: "R0")
    d.decision.should eq("require_approval")
    d.matched_policy.should eq("stricter_local_policy")
    d.effective_ceiling.should eq("R0")
  end

  it "capability ceiling of none turns automation off entirely" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: "R0", ceiling: "R2", capability_ceiling: "none")
    d.decision.should eq("require_approval")
  end

  it "a looser capability ceiling cannot widen a strict instance ceiling" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: "R1", ceiling: "R0", capability_ceiling: "R2")
    d.decision.should eq("require_approval")
    d.matched_policy.should eq("above_ceiling")
    d.effective_ceiling.should eq("R0")
  end

  it "within-ceiling classes auto-approve" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "notes.label", action_class: "R1", ceiling: "R1")
    d.decision.should eq("auto_approve")
    d.matched_policy.should eq("within_ceiling")
    d.auto_approved.should be_true
    d.effective_ceiling.should eq("R1")
  end

  it "an invalid capability ceiling fails closed rather than widening" do
    d = Chronicle::Authority.evaluate_action_authority(capability: "x.y", action_class: "R0", ceiling: "R2", capability_ceiling: "R9")
    d.decision.should eq("require_approval")
    d.matched_policy.should eq("fail_closed_invalid_capability_ceiling")
    d.effective_ceiling.should eq("R2")
  end

  it "validate_ceiling rejects R3, R4, and garbage" do
    {"R3", "R4", "medium", "", "NONE", "r1"}.each do |bad|
      expect_raises(ArgumentError, /ceiling/) do
        Chronicle::Authority.validate_ceiling(bad)
      end
    end
  end

  it "validate_ceiling accepts none, R0, R1, R2" do
    {"none", "R0", "R1", "R2"}.each do |good|
      Chronicle::Authority.validate_ceiling(good)
    end
  end
end

describe Chronicle::Runtime do
  it "emits an authority.decision audit event naming class, ceiling, policy, decision" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    rt.set_authority_ceiling("R1", actor: "owner", reason: "raise")
    decision = rt.evaluate_capability_authority(
      capability: "notes.label", action_class: "R2",
      capability_ceiling: "R1", actor: "gateway",
    )

    events = store.iter_events.select { |e| e.type == "authority.decision" }
    events.size.should eq(1)
    payload = JSON.parse(events[0].payload).as_h
    payload["capability"].as_s.should eq("notes.label")
    payload["action_class"].as_s.should eq("R2")
    payload["ceiling"].as_s.should eq("R1")
    payload["capability_ceiling"].as_s.should eq("R1")
    payload["effective_ceiling"].as_s.should eq("R1")
    payload["matched_policy"].as_s.should eq("above_ceiling")
    payload["decision"].as_s.should eq("require_approval")
    events[0].actor.should eq("gateway")
    decision.event_id.should eq(events[0].id)
  end

  it "set_authority_ceiling emits a ceiling_changed audit event and returns its id" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    event_id = rt.set_authority_ceiling("R1", actor: "owner", reason: "turn on")
    events = store.iter_events.select { |e| e.type == "authority.ceiling_changed" }
    events.size.should eq(1)
    event = events.first
    event.id.should eq(event_id)
    payload = JSON.parse(event.payload).as_h
    payload["ceiling"].as_s.should eq("R1")
    payload["previous_ceiling"].as_s.should eq("none")
    payload["actor"].as_s.should eq("owner")
    payload["reason"].as_s.should eq("turn on")
  end

  it "set_authority_ceiling rejects R3/R4/garbage before any event" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    {"R3", "R4", "medium", "", "NONE", "r1"}.each do |bad|
      expect_raises(ArgumentError, /ceiling/) do
        rt.set_authority_ceiling(bad, actor: "owner", reason: "try")
      end
    end
    store.iter_events.select { |e| e.type == "authority.ceiling_changed" }.should be_empty
    rt.authority_ceiling.should eq("none")
  end

  it "set_authority_ceiling requires non-empty actor and reason" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    expect_raises(ArgumentError, /actor/) { rt.set_authority_ceiling("R1", actor: "  ", reason: "why") }
    expect_raises(ArgumentError, /reason/) { rt.set_authority_ceiling("R1", actor: "owner", reason: "") }
  end

  it "authority events never schedule behaviors" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    rt.set_authority_ceiling("R1", actor: "owner", reason: "probe")
    rt.evaluate_capability_authority(capability: "x.y", action_class: "R0")
    rt.run_until_idle
    store.iter_events.select { |e| e.type == "behavior.started" }.should be_empty
  end

  it "ceiling survives load and fork" do
    db = File.join(Dir.tempdir, "chronicle_authority_#{Random::Secure.hex(4)}.db")
    store = Chronicle::SQLiteEventStore.new(db, run_id: "auth_run")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph, run_id: store.run_id)
    event_id = rt.set_authority_ceiling("R1", actor: "owner", reason: "persist me")

    loaded = Chronicle::Runtime(PackModel).load(
      db, rt.run_id, Crig::Agent(PackModel).new(model: PackModel.new, preamble: ""), max_turns: 1
    )
    loaded.authority_ceiling.should eq("R1")

    fork = rt.fork(at_event: event_id)
    fork.authority_ceiling.should eq("R1")
  end
end
