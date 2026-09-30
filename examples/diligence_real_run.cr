require "./support/example_support"

# Port of vendor/activegraph/examples/diligence_real_run.py (the v0.9
# contract): load the Diligence pack, run it end-to-end on scripted fixtures,
# verify the memo bar, demo the memo_approval policy, fork with an alternative
# thesis and diff, export the trace, and walk a causal chain.
#
# Port divergence: the Crystal Diligence pack ships a single-company fixture
# set (upstream runs three). The pack, memo bar, approval gate, fork/diff,
# export, and causal chain are unchanged.

def diligence_runtime(db : String, run_id : String, responses : Array(String), settings : Hash(String, JSON::Any)? = nil)
  File.delete(db) if File.exists?(db)
  model = ExampleSupport::ScriptedModel.new(responses)
  store = Chronicle::SQLiteEventStore.new(db, run_id: run_id)
  evt_store, graph, runtime = ExampleSupport.build(model, store: store, run_id: run_id)
  runtime.load_pack(Chronicle::Packs::Diligence::PACK, settings: settings)
  {evt_store, graph, runtime}
end

def print_run_summary(runtime, graph) : Nil
  by_type = Hash(String, Int32).new(0)
  graph.all_objects.each { |object| by_type[object.type] += 1 }
  puts "[step 1] run #{runtime.run_id}: #{runtime.store.iter_events.size} events"
  {"company", "document", "question", "claim", "evidence", "contradiction", "risk", "memo"}.each do |type|
    puts "  #{type.ljust(14)} #{by_type[type]? || 0}"
  end
end

def check_memo_structure(memo) : Nil
  body = JSON.parse(memo.data).as_h
  {"summary", "thesis_questions_addressed", "key_claims", "open_contradictions", "risks"}.each do |section|
    raise "memo #{memo.id} missing section #{section.inspect}" unless body.has_key?(section)
  end
  body["key_claims"].as_a.each do |claim|
    unless claim.as_h["evidence_ids"]?.try(&.as_a?)
      raise "memo #{memo.id}: claim #{claim.as_h["claim_id"]?} has no evidence_ids"
    end
  end
  contradictions = body["open_contradictions"].as_a
  if contradictions.empty? && body["contradictions_note"]?.try(&.as_s?) != "no contradictions found"
    raise "memo #{memo.id}: zero contradictions and no explicit note"
  end
  raise "memo #{memo.id}: zero risks identified" if body["risks"].as_a.empty?
end

def diligence_real_run_main
  responses = [
    %({"questions":["What is their moat?","Who are competitors?"]}),
    %({"document_url":"https://northwind.example/10k","summary":"Annual report","claims":[
        {"text":"Revenue grew 18%","confidence":0.9,"evidence_quote":"Revenue grew 18% YoY"},
        {"text":"Revenue fell 7% per survey","confidence":0.85,"evidence_quote":"Survey shows -7%","contradicts_claim_text":"Revenue grew 18%"}
      ]}),
    %({"document_url":"https://northwind.example/competitors","summary":"Competitor analysis","claims":[
        {"text":"Competitors are emerging","confidence":0.6}
      ]}),
    %({"summary":"Northwind Robotics memo","thesis_questions_addressed":[{"question":"What is their moat?"}],"key_claims":[{"claim_id":"c1","evidence_ids":["e1"]}],"open_contradictions":[{"claim_a_id":"c1","claim_b_id":"c2"}],"risks":[{"title":"Growth dispute","description":"Revenue figures conflict"}]}),
  ]

  db = File.join(Dir.tempdir, "chronicle_diligence_real_run.db")
  trace = File.join(Dir.tempdir, "chronicle_diligence_real_run.trace.jsonl")

  # ---- step 1: load the pack and run one company end-to-end ----------------
  _evt_store, graph, runtime = diligence_runtime(db, "parent", responses.dup)
  runtime.run_goal("Diligence: Northwind Robotics")
  runtime.save_state
  print_run_summary(runtime, graph)

  # ---- verify the memo bar -------------------------------------------------
  puts "\n=== verifying memo bar ==="
  memos = graph.all_objects.select { |object| object.type == "memo" }
  raise "expected at least one memo" if memos.empty?
  memos.each { |memo| check_memo_structure(memo) }
  puts "OK: #{memos.size} memo(s), all with required structure and provenance"

  # ---- step 2: memo_approval policy demo ----------------------------------
  puts "\n=== memo_approval policy demo ==="
  _approval_store, approval_graph, approval_rt = diligence_runtime(
    db + ".approval", "approval-demo", responses.dup,
    settings: {"auto_approve_memos" => JSON::Any.new(false)},
  )
  approval_rt.run_goal("Diligence: Northwind Robotics")
  round = 0
  loop do
    pending = approval_rt.pack_pending_approvals
    if pending.empty?
      puts "after approval: 0 pending"
      break
    end
    round += 1
    label = round > 1 ? "round #{round}" : "initial"
    puts "pending approvals (#{pending.size}, #{label}):"
    pending.each do |approval|
      puts "  - #{approval.object_type.ljust(12)} #{approval.id} reason=#{approval.reason.inspect}"
      approval_rt.approve_pack(approval.id, approved_by: "demo-user")
    end
    approval_rt.run_until_idle
  end
  puts "materialized memos: #{approval_graph.all_objects.count { |object| object.type == "memo" }}"

  # ---- step 3: fork with an alternative thesis and diff -------------------
  puts "\n=== fork with alternative thesis ==="
  goal_event = runtime.store.iter_events.find { |event| event.type == "goal.created" }.not_nil!
  fork = runtime.fork(at_event: goal_event.id, label: "alt-thesis", replay_llm_cache: true, replay_tool_cache: true)
  # Re-load the pack with a higher review threshold. `load_pack` is idempotent
  # on (name, version) upstream too (CONTRACT v0.9 #6), so this mirrors the
  # vendor call exactly; the recorded prompts still replay from cache.
  fork.load_pack(Chronicle::Packs::Diligence::PACK, settings: {"confidence_threshold_for_review" => JSON::Any.new(0.9)})
  fork.run_until_idle
  fork.save_state

  diff = runtime.diff(fork)
  puts "parent run:  #{runtime.run_id}"
  puts "fork run:    #{fork.run_id}"
  puts "shared events:        #{diff.shared_events.size}"
  puts "parent-only events:   #{diff.parent_only_events.size}"
  puts "fork-only events:     #{diff.fork_only_events.size}"
  puts "divergent objects:    #{diff.divergent_objects.size}"

  # ---- step 4: export the trace as JSONL ----------------------------------
  File.open(trace, "w") do |io|
    runtime.store.iter_events.each { |event| io.puts event.canonical_json }
  end
  puts "\n=== trace exported ===\n#{trace}  (#{File.read_lines(trace).size} events)"

  # ---- step 5: causal chain for one final claim ---------------------------
  puts "\n=== causal chain for one final claim ==="
  final_claim = graph.all_objects.find { |object| object.type == "claim" }
  if final_claim
    puts Chronicle::Trace.causal_chain(runtime.store.iter_events, graph, final_claim.id)
  else
    puts "(no claims produced; skipping)"
  end

  [db, db + ".approval", trace].each { |path| File.delete(path) if File.exists?(path) }
end

diligence_real_run_main
