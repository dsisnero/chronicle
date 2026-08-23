require "../spec_helper"

# Causal-chain LLM/tool weave. Ported from activegraph trace/causal.py
# (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616): objects created
# inside an @llm_behavior handler carry llm_request_event_id +
# tool_request_event_ids in provenance (CONTRACT v0.6 #15, v0.7 #19), and
# causal_chain renders the LLM round-trip (llm.requested + llm.responded with
# model/cost/cache) and each tool round-trip (tool.requested + tool.responded
# with tool name/error/cost/cache) before walking the caused_by chain.

module CausalWeaveHelper
  extend self

  def ev(id : String, type : String, caused_by : String?, payload : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: 0_u64, id: id,
      type: type, actor: "test", caused_by: caused_by,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: payload,
    )
  end

  def apply(events : Array(Chronicle::Event)) : Chronicle::GraphProjection
    events.reduce(Chronicle::GraphProjection.empty) { |g, e| g.apply(e) }
  end
end

describe Chronicle::Trace do
  it "weaves the LLM round-trip into the causal chain" do
    goal = CausalWeaveHelper.ev("goal_1", "goal.created", nil, %({"goal":"audit"}))
    doc = CausalWeaveHelper.ev("evt_doc", "object.created", "goal_1", %({"id":"doc#1","type":"document","data":{"title":"src"}}))
    req = CausalWeaveHelper.ev("llm_req_1", "llm.requested", "evt_doc", %({"model":"claude-sonnet-4-5"}))
    resp = CausalWeaveHelper.ev("llm_resp_1", "llm.responded", "llm_req_1", %({"cost_usd":"0.001","cache_hit":false}))
    claim = CausalWeaveHelper.ev("evt_claim", "object.created", "evt_doc",
      %({"id":"claim#1","type":"claim","data":{"text":"market is growing"},"provenance":{"llm_request_event_id":"llm_req_1"}}))
    events = [goal, doc, req, resp, claim]

    chain = Chronicle::Trace.causal_chain(events, CausalWeaveHelper.apply(events), "claim#1")
    lines = chain.lines
    # First line names the claim object.
    lines[0].should contain("claim#1 (claim)")
    # The LLM round-trip is woven in with model + cost.
    full = chain
    full.should contain("llm.requested")
    full.should contain("model=claude-sonnet-4-5")
    full.should contain("llm.responded")
    full.should contain("cost=$0.001")
    # The walk continues to the goal.
    full.should contain("goal_1")
  end

  it "weaves every tool round-trip into the causal chain" do
    goal = CausalWeaveHelper.ev("goal_1", "goal.created", nil, %({"goal":"g"}))
    doc = CausalWeaveHelper.ev("evt_doc", "object.created", "goal_1", %({"id":"doc#1","type":"document","data":{"title":"t"}}))
    req = CausalWeaveHelper.ev("llm_req_1", "llm.requested", "evt_doc", %({"model":"m"}))
    resp = CausalWeaveHelper.ev("llm_resp_1", "llm.responded", "llm_req_1", %({"cost_usd":"0.001"}))
    tr1 = CausalWeaveHelper.ev("tr1", "tool.requested", "llm_req_1", %({"tool":"t1"}))
    tr1r = CausalWeaveHelper.ev("tr1_resp", "tool.responded", "tr1", %({"tool":"t1"}))
    tr2 = CausalWeaveHelper.ev("tr2", "tool.requested", "llm_req_1", %({"tool":"t2"}))
    tr2r = CausalWeaveHelper.ev("tr2_resp", "tool.responded", "tr2", %({"tool":"t2"}))
    claim = CausalWeaveHelper.ev("evt_claim", "object.created", "evt_doc",
      %({"id":"claim#1","type":"claim","data":{"text":"x"},"provenance":{"llm_request_event_id":"llm_req_1","tool_request_event_ids":["tr1","tr2"]}}))
    events = [goal, doc, req, resp, tr1, tr1r, tr2, tr2r, claim]

    chain = Chronicle::Trace.causal_chain(events, CausalWeaveHelper.apply(events), "claim#1")
    chain.should contain("llm.requested")
    chain.should contain("tool=t1")
    chain.should contain("tool=t2")
    chain.should contain("goal_1")
  end

  it "renders cache-hit and error tails in the weave" do
    goal = CausalWeaveHelper.ev("goal_1", "goal.created", nil, %({"goal":"g"}))
    doc = CausalWeaveHelper.ev("evt_doc", "object.created", "goal_1", %({"id":"doc#1","type":"document","data":{"title":"t"}}))
    req = CausalWeaveHelper.ev("llm_req_1", "llm.requested", "evt_doc", %({"model":"m"}))
    resp = CausalWeaveHelper.ev("llm_resp_1", "llm.responded", "llm_req_1", %({"cache_hit":true}))
    tr = CausalWeaveHelper.ev("tr1", "tool.requested", "llm_req_1", %({"tool":"t1"}))
    trerr = CausalWeaveHelper.ev("tr1_resp", "tool.responded", "tr1", %({"tool":"t1","error":{"reason":"tool.network_error"}}))
    claim = CausalWeaveHelper.ev("evt_claim", "object.created", "evt_doc",
      %({"id":"claim#1","type":"claim","data":{"text":"x"},"provenance":{"llm_request_event_id":"llm_req_1","tool_request_event_ids":["tr1"]}}))
    events = [goal, doc, req, resp, tr, trerr, claim]

    chain = Chronicle::Trace.causal_chain(events, CausalWeaveHelper.apply(events), "claim#1")
    chain.should contain("(cache_hit)")
    chain.should contain("error=tool.network_error")
  end

  it "leaves the chain unchanged for a non-LLM object" do
    goal = CausalWeaveHelper.ev("goal_1", "goal.created", nil, %({"goal":"g"}))
    task = CausalWeaveHelper.ev("evt_task", "object.created", "goal_1", %({"id":"task#1","type":"task","data":{"title":"Work"}}))
    events = [goal, task]

    chain = Chronicle::Trace.causal_chain(events, CausalWeaveHelper.apply(events), "task#1")
    chain.should_not contain("llm.requested")
    chain.should contain("goal_1")
  end
end
