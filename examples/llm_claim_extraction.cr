require "./support/example_support"

# Port of vendor/activegraph/examples/llm_claim_extraction.py (the v0.6
# contract): `@[LLMBehavior]` with a structured output schema, a
# `@[RelationBehavior]`, a scripted provider, a SQLite-persisted run forked
# with `replay_llm_cache: true`, and a `causal_chain` query.
#
# The demo ships its responses inline so it runs offline — the Crystal analogue
# of upstream's `_DemoScriptedProvider`.

LLM_CLAIM_DOCUMENTS = [
  {"Q3 sales summary", "Q3 sales results show 14% YoY growth in the SMB segment, while enterprise contracts declined 3% over the same period."},
  {"Model card v4", "The v4 model achieves a 22% relative improvement on GSM8K over our previous best, with no regression on HumanEval."},
  {"Anecdotal retention chatter", "Some users have mentioned that retention might be slipping a bit in recent months, though we don't have hard numbers yet."},
]

module LlmClaimExtractionExample
  include Chronicle::Packs::DSL

  # Structured output schema (upstream Pydantic Claim / ClaimList).
  struct Claim
    include JSON::Serializable
    property text : String
    property confidence : Float64
    property evidence_span : String
  end

  struct ClaimList
    include JSON::Serializable
    property claims : Array(Claim)
  end

  @[Behavior(name: "planner", on: ["goal.created"])]
  def planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    LLM_CLAIM_DOCUMENTS.each do |title, body|
      graph.add_object("document", %({"title":#{title.to_json},"body":#{body.to_json}}))
    end
  end

  @[LLMBehavior(name: "claim_extractor", on: ["object.created"],
    where: {"type" => "document"}, output_schema: ClaimList,
    description: "Extract verifiable factual claims from the document.")]
  def claim_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, llm_output : ClaimList)
    doc_id = JSON.parse(event.payload)["id"].as_s
    llm_output.claims.each do |claim|
      object = graph.add_object("claim", JSON.build do |json|
        json.object do
          json.field "text", claim.text
          json.field "confidence", claim.confidence
          json.field "evidence_span", claim.evidence_span
          json.field "status", "open"
        end
      end)
      graph.add_relation(object.id, doc_id, "supports")
    end
  end

  @[Behavior(name: "confidence_check", on: ["object.created"], where: {"type" => "claim"})]
  def confidence_check(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    payload = JSON.parse(event.payload).as_h
    if payload["data"].as_h["confidence"].as_f < 0.5
      graph.patch_object(payload["id"].as_s, %({"status":"needs_review"}))
    end
  end

  @[RelationBehavior(name: "link_logger", relation_type: "supports", on: ["relation.created"])]
  def link_logger(relation : Chronicle::GraphRelation, event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    document = graph.get_object(relation.to_id)
    return if document.nil?
    return if JSON.parse(document.data).as_h["has_claims"]?
    graph.patch_object(relation.to_id, %({"has_claims":true}))
  end

  pack(name: "llmclaimextraction", version: "0.1.0")
end

def llm_claim_extraction_main
  # Canned model output, in the deterministic order the documents dispatch.
  responses = [
    %({"claims":[{"text":"SMB segment grew 14% YoY in Q3.","confidence":0.9,"evidence_span":"14% YoY growth in the SMB segment"},{"text":"Enterprise contracts declined 3% in Q3.","confidence":0.9,"evidence_span":"enterprise contracts declined 3%"}]}),
    %({"claims":[{"text":"v4 model improves GSM8K by 22% over the prior best.","confidence":0.85,"evidence_span":"22% relative improvement on GSM8K over our previous best"},{"text":"v4 model does not regress on HumanEval.","confidence":0.7,"evidence_span":"no regression on HumanEval"}]}),
    %({"claims":[{"text":"Retention may be declining in recent months.","confidence":0.4,"evidence_span":"retention might be slipping a bit"}]}),
  ]

  db = File.join(Dir.tempdir, "chronicle_llm_claim_extraction.db")
  File.delete(db) if File.exists?(db)

  # ---- step 1: run with the scripted provider -----------------------------
  model = ExampleSupport::ScriptedModel.new(responses)
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
  _evt_store, graph, runtime = ExampleSupport.build(model, store: store, run_id: "parent")
  runtime.load_pack(LlmClaimExtractionExample::PACK)
  runtime.run_goal("Survey Q3 market signals")
  runtime.save_state
  puts "[step 1] run #{runtime.run_id}: #{graph.all_objects.size} objects, #{graph.all_relations.size} relations"

  # ---- step 2: fork at the goal with the LLM cache ------------------------
  # The prompt is assembled through the vendor pipeline (system + scoped view +
  # volatile-stripped event + instruction) and hashed per turn, so the fork
  # rebuilds byte-identical prompts and serves every response from the parent's
  # recorded llm.responded events — zero new model calls.
  goal_event = runtime.store.iter_events.find { |event| event.type == "goal.created" }.not_nil!
  fork = runtime.fork(at_event: goal_event.id, label: "cached-replay", replay_llm_cache: true)
  fork.run_until_idle
  fork.save_state
  cache_hits = fork.store.iter_events.count do |event|
    event.type == "llm.responded" && JSON.parse(event.payload).as_h["cache_hit"]?.try(&.as_bool?) == true
  end
  harvested = Chronicle::LLMCache.from_events(runtime.store.iter_events)
  puts "[step 2] fork #{fork.run_id}: parent recorded #{harvested.size} cache entries; served #{cache_hits} from cache"

  # ---- step 3: print both traces ------------------------------------------
  puts "\n=== parent trace ==="
  ExampleSupport.print_trace(runtime)
  puts "\n=== fork trace (replay_llm_cache=true) ==="
  ExampleSupport.print_trace(fork)

  # ---- step 4: causal chain for the first claim ---------------------------
  first_claim = graph.all_objects.find { |object| object.type == "claim" }
  if first_claim
    puts "\n=== causal chain for #{first_claim.id} ==="
    puts Chronicle::Trace.causal_chain(runtime.store.iter_events, graph, first_claim.id)
  end

  File.delete(db) if File.exists?(db)
end

llm_claim_extraction_main
