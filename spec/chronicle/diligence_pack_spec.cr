require "../spec_helper"

# The diligence reference pack (upstream activegraph.packs.diligence) ported
# onto the Crystal pack DSL. Runs the full flow end-to-end against a scripted
# Crig provider (no network):
#
#   goal.created -> company_planner (company)
#   company.created -> question_generator (LLM + settings: questions)
#   question.created -> claim_extractor (LLM + tool: claims + evidence +
#                        contradicts edge)
#   contradicts edge -> contradiction_detector (pattern: contradiction)
#   contradiction.created -> memo_synthesizer (LLM: memo behind policy)
#
# Asserted: object/relation types validate, canonical prefixed behavior names,
# settings bounds honored, the pattern subscription fires, and the memo lands
# (materialized under auto_approve_memos, proposed + approve_pack otherwise).

class DiligenceScriptedModel
  include Crig::Completion::CompletionModel

  getter calls : Int32 = 0
  @responses : Array(String)

  def initialize(@responses : Array(String))
  end

  def completion(request : Crig::Completion::Request::CompletionRequest)
    @calls += 1
    text = @responses.shift? || "{}"
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(text)
      ),
      Crig::Completion::Usage.new(input_tokens: 5_i64, output_tokens: 5_i64),
      "raw",
      "msg_#{@calls}",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

private def diligence_scripted
  DiligenceScriptedModel.new([
    %({"questions":["What is their moat?","Who are competitors?"]}),
    %({"document_url":"https://northwind.example/10k","summary":"Annual report","claims":[
        {"text":"Revenue grew 18%","confidence":0.9,"evidence_quote":"Revenue grew 18% YoY"},
        {"text":"Revenue fell 7% per survey","confidence":0.85,"evidence_quote":"Survey shows -7%","contradicts_claim_text":"Revenue grew 18%"}
      ]}),
    %({"document_url":"https://northwind.example/competitors","summary":"Competitor analysis","claims":[
        {"text":"Competitors are emerging","confidence":0.6}
      ]}),
    %({"summary":"Northwind Robotics memo","thesis_questions_addressed":[{"question":"What is their moat?"}],"key_claims":[{"claim_id":"c1","evidence_ids":["e1"]}],"open_contradictions":[{"claim_a_id":"c1","claim_b_id":"c2"}],"risks":[{"title":"Growth dispute","description":"Revenue figures conflict"}]}),
  ])
end

private def diligence_runtime(model : DiligenceScriptedModel = diligence_scripted, settings : Hash(String, JSON::Any)? = nil)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(DiligenceScriptedModel).new(model: model, preamble: "")
  la = Chronicle::LogAgent(DiligenceScriptedModel).new(agent, store: store, max_turns: 1)
  worker = Chronicle::ModelEffectWorker.new(
    Chronicle::FixedModelExecutor(DiligenceScriptedModel).new(model),
  )
  rt = Chronicle::Runtime(DiligenceScriptedModel).new(
    store: store, log_agent: la, graph: graph, model_effect_worker: worker,
  )
  rt.load_pack(Chronicle::Packs::Diligence::PACK, settings: settings)
  {store, graph, rt}
end

describe "diligence reference pack" do
  it "runs the full flow end-to-end and materializes a memo" do
    store, graph, rt = diligence_runtime
    rt.run_goal("Diligence: Northwind Robotics")

    objects = graph.all_objects.to_h { |o| {o.type, o} }
    objects.has_key?("company").should be_true
    objects.has_key?("question").should be_true
    objects.has_key?("claim").should be_true
    objects.has_key?("evidence").should be_true
    objects.has_key?("contradiction").should be_true
    objects.has_key?("memo").should be_true

    company = objects["company"]
    JSON.parse(company.data)["name"].as_s.should eq("Northwind Robotics")

    questions = graph.all_objects.select { |o| o.type == "question" }
    questions.size.should eq(2)
    questions.all? { |q| JSON.parse(q.data)["status"].as_s == "answered" }.should be_true

    contradiction = objects["contradiction"]
    JSON.parse(contradiction.data)["status"].as_s.should eq("open")

    memo = objects["memo"]
    JSON.parse(memo.data)["summary"].as_s.should eq("Northwind Robotics memo")

    store.iter_events.any? { |e| e.type == "behavior.failed" }.should be_false
  end

  it "uses canonical prefixed behavior names and registered pack identity" do
    _store, _graph, rt = diligence_runtime
    rt.loaded_packs.should eq(["diligence"])
    rt.get_behavior("question_generator").name.should eq("diligence.question_generator")
    rt.get_behavior("claim_extractor").name.should eq("diligence.claim_extractor")
    rt.get_tool("summarize_document").not_nil!.name.should eq("diligence.summarize_document")
  end

  it "honors the settings bounds (max_questions)" do
    _store, graph, rt = diligence_runtime(settings: {"max_questions" => JSON::Any.new(1_i64)})
    rt.run_goal("Diligence: Northwind Robotics")

    questions = graph.all_objects.select { |o| o.type == "question" }
    questions.size.should eq(1)
  end

  it "proposes the memo behind the policy when auto_approve_memos is false, then approve_pack materializes it" do
    store, graph, rt = diligence_runtime(settings: {"auto_approve_memos" => JSON::Any.new(false)})
    rt.run_goal("Diligence: Northwind Robotics")

    graph.all_objects.none? { |o| o.type == "memo" }.should be_true
    approvals = rt.pack_pending_approvals.select { |a| a.object_type == "memo" }
    approvals.size.should eq(1)

    obj = rt.approve_pack(approvals[0].id, approved_by: "owner")
    obj.type.should eq("memo")
    JSON.parse(obj.data)["summary"].as_s.should eq("Northwind Robotics memo")
  end
end
