require "../src/clarity"

# Demonstrate the full event-sourcing cycle:
# 1. Run an agent → events saved to SQLite
# 2. Fork at a sequence point → create a branch
# 3. Replay events → reconstruct graph state
# 4. Structural diff between original and fork

DB_PATH = "/tmp/_clarity_demo.db"
RUN_ID  = "demo_run"

def run_demo
  puts "=" * 60
  puts "Clarity: Event-Sourced Agent — Save, Patch, Replay"
  puts "=" * 60

  # Phase 1: Create a SQLite-backed store and run an agent
  puts "\n[1] Running agent with SQLiteEventStore..."
  File.delete(DB_PATH) if File.exists?(DB_PATH)

  store = Clarity::SQLiteEventStore.new(DB_PATH, RUN_ID)
  graph = Clarity::GraphProjection.empty

  # Create objects directly (simulating what a behavior would do)
  evt1 = Clarity::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: "evt_001",
    type: "object.created", actor: "user", caused_by: nil,
    timestamp: Time.utc, payload: %({"id":"obj_001","type":"task","data":{"status":"pending","priority":"low"}}),
  )
  graph = graph.apply(evt1)
  store.append(evt1)

  evt2 = Clarity::Event.new(
    schema_version: 1_u16, sequence: 2_u64, id: "evt_002",
    type: "object.created", actor: "user", caused_by: "evt_001",
    timestamp: Time.utc, payload: %({"id":"obj_002","type":"claim","data":{"assignee":"alice"}}),
  )
  graph = graph.apply(evt2)
  store.append(evt2)

  # Phase 1b: Apply a patch via the auto-apply shortcut
  puts "  Applying patch to obj_001 status: pending → in_progress"
  result = graph.patch_object("obj_001", %({"status":"in_progress","priority":"high"}), actor: "system")
  graph = result.graph
  # Record the patch event
  evt3 = Clarity::Event.new(
    schema_version: 1_u16, sequence: 3_u64, id: "evt_003",
    type: "patch.applied", actor: "system", caused_by: "evt_001",
    timestamp: Time.utc,
    payload: %({"patch":{"id":"patch_001","target":"obj_001","op":"update","value":{"status":"in_progress","priority":"high"},"expected_version":1,"proposed_by":"system","status":"applied"},"target":"obj_001","diff":#{result.diff || "{}"}}),
  )
  store.append(evt3)

  puts "  Objects in graph: #{graph.objects.size}"
  obj = graph.get_object("obj_001")
  puts "  obj_001 data: #{obj ? obj.data : "NIL"}"
  puts "  obj_001 version: #{obj ? obj.version : 0}"
  store.close

  # Phase 2: Fork the event log at sequence point 2 (before the patch)
  puts "\n[2] Forking event log at sequence 2 (before patch)..."
  File.delete("/tmp/_clarity_demo_fork.db") if File.exists?("/tmp/_clarity_demo_fork.db")
  fork_run_id = "fork_run"

  # Read original events, fork at seq 2
  orig_store = Clarity::SQLiteEventStore.new(DB_PATH, RUN_ID)
  events = orig_store.iter_events(before: "evt_002")
  orig_store.close

  # Write forked events to new store
  fork_store = Clarity::SQLiteEventStore.new("/tmp/_clarity_demo_fork.db", fork_run_id)
  events.each { |e| fork_store.append(e) }

  # Replay fork into a fresh graph
  fork_graph = Clarity::GraphProjection.empty
  fork_events = fork_store.iter_events
  fork_events.each { |e| fork_graph = fork_graph.apply(e) }
  puts "  Fork has #{fork_graph.objects.size} objects"
  fork_obj = fork_graph.get_object("obj_001")
  puts "  Fork obj_001 status: #{fork_obj ? fork_obj.data : "NIL"}"
  fork_store.close

  # Phase 3: Apply a DIFFERENT patch on the fork (better outcome)
  puts "\n[3] Applying different patch on fork (priority: critical)..."
  fork_result = fork_graph.patch_object("obj_001", %({"status":"in_progress","priority":"critical"}), actor: "system")
  fork_graph = fork_result.graph
  obj = fork_graph.get_object("obj_001")
  puts "  Fork obj_001 data: #{obj ? obj.data : "NIL"}"
  puts "  Fork obj_001 version: #{obj ? obj.version : 0}"

  # Phase 4: Replay original from store and diff with fork
  puts "\n[4] Replaying original from store..."
  replay_store = Clarity::SQLiteEventStore.new(DB_PATH, RUN_ID)
  replay_events = replay_store.iter_events
  replay_graph = Clarity::GraphProjection.replay(replay_events)
  replay_store.close

  puts "  Replay has #{replay_graph.objects.size} objects"
  replay_obj = replay_graph.get_object("obj_001")
  puts "  Replay obj_001 data: #{replay_obj ? replay_obj.data : "NIL"}"

  # Structural diff
  puts "\n[5] Structural diff (original vs fork):"
  diff = fork_graph.diff(replay_graph)
  puts "  Different patches: added=#{diff.added_patch_ids.size} removed=#{diff.removed_patch_ids.size}"
  puts "  Different objects: added=#{diff.added_object_ids.size} removed=#{diff.removed_object_ids.size}"
  puts "\n  Original had: priority=high, Fork has: priority=critical"
  puts "  → Fork achieved a better outcome by taking a different path."

  # Phase 5: Cleanup
  File.delete(DB_PATH) if File.exists?(DB_PATH)
  File.delete("/tmp/_clarity_demo_fork.db") if File.exists?("/tmp/_clarity_demo_fork.db")

  puts "\n" + "=" * 60
  puts "Done — full event-sourcing cycle demonstrated."
  puts "=" * 60
end

run_demo
