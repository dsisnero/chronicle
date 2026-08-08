module Chronicle
  # Agent harness runtime — orchestrates the event loop, budget, and
  # LogAgent execution. Ported from activegraph.runtime.runtime.Runtime.
  class Runtime(M)
    getter store : EventStore
    getter log_agent : LogAgent(M)
    getter run_id : String
    @decision : Routing::RouteDecision?
    @execution_targets = [] of Routing::Target
    @execution_target_index = 0
    @approvals : ApprovalAdapter = ApprovalAdapter.new
    @authority_ceiling : String? = nil
    @frame_stack : FrameStack = FrameStack.new
    @pack_state : Packs::PackRuntimeState = Packs::PackRuntimeState.new
    @pack_behaviors : Array(Packs::PackBehavior) = [] of Packs::PackBehavior
    @pack_tools : Array(Tool) = [] of Tool
    @pack_warnings : Array(String) = [] of String
    @graph : GraphProjection?
    @dispatch_cursor : Int32 = 0
    @tool_approval_policies : Array(Policy) = [] of Policy
    @delayed : Packs::DelayedQueue = Packs::DelayedQueue.new
    @metrics : Metrics = NoOpMetrics.new

    # Action-class authority scale, lowest to highest.
    AUTHORITY_RANKS = {"read" => 0, "write" => 1, "admin" => 2, "root" => 3}

    # Budget limits for a run.
    struct Budget
      getter max_events : Int64

      def initialize(@max_events : Int64 = 1000)
      end
    end

    def initialize(
      @store : EventStore,
      @log_agent : LogAgent(M),
      @policy : Routing::Policy? = nil,
      @budget : Budget = Budget.new,
      @available_targets : Array(Routing::Target) = [] of Routing::Target,
      @run_id : String = "default",
      @model_effect_worker : ModelEffectWorker? = nil,
      @llm_cache : LLMCache? = nil,
      @strict_expected_hashes : Array(String)? = nil,
      @tools : Array(Tool) = [] of Tool,
      @tool_cache : ToolCache? = nil,
      @graph : GraphProjection? = nil,
      @tool_approval_policies : Array(Policy) = [] of Policy,
      @metrics : Metrics = NoOpMetrics.new,
    )
    end

    # Run a prompt through the harness.
    # 1. Creates a goal.created event
    # 2. Routes (if policy provided)
    # 3. Drives the LogAgent through the model/tool loop
    # 4. Records all events to the store
    @response_text : String = ""

    def run(prompt : String, caused_by : String? = nil, max_steps : Int32? = nil) : String
      # Emit goal.created
      goal_event = Event.new(
        schema_version: 1_u16, sequence: next_seq, id: "goal_created_#{next_seq}",
        type: "goal.created", actor: "user", caused_by: caused_by,
        timestamp: Time.utc, payload: JSON.build do |json|
        json.object { json.field "goal", prompt }
      end,
      )
      @store.append(goal_event)
      user_message = record_chat_message("user", prompt, goal_event.id)
      return @response_text if budget_exhausted?

      # Route if we have a policy
      if policy = @policy
        targets = @available_targets
        if targets.empty?
          targets = policy.configured_targets
        end
        request = Routing::Request.new(
          prompt, nil, nil, [] of String,
          [] of Routing::ContextCandidate, nil, 50,
        )
        decision = Routing::Router.new.preview(request, policy, targets)
        @decision = decision
        @execution_targets = decision.eligible_targets
        @execution_target_index = 0
        record_routing_decision(decision, user_message.id)
      end

      # Drive LogAgent
      msg = Crig::Completion::Message.user(prompt)
      @log_agent.start(msg)

      drive_loop(user_message, max_steps)
      @response_text
    end

    # Run the loop for at most `steps` iterations (a bounded quantum).
    def run_quantum(prompt : String, steps : Int32, caused_by : String? = nil) : String
      run(prompt, caused_by: caused_by, max_steps: steps)
    end

    # Drain a bounded cooperative quantum without claiming false idle
    # (CONTRACT v1.10 #3). Hosts with a single graph-writer thread can
    # interleave reads and commands between quanta. Bounds are checked
    # between queue events; one behavior invocation remains atomic. When
    # work remains, no `runtime.idle` marker is emitted. The normal
    # idle/budget marker is emitted exactly when this quantum actually
    # reaches that state. Ported from
    # activegraph.runtime.runtime.Runtime#run_quantum.
    def run_quantum(
      *,
      max_queue_events : Int32 = 25,
      max_seconds : Float64 = 0.25,
    ) : RunQuantumResult
      raise ArgumentError.new("max_queue_events must be >= 1") if max_queue_events < 1
      raise ArgumentError.new("max_seconds must be finite and > 0") unless max_seconds.finite? && max_seconds > 0

      if @pack_behaviors.empty?
        # Nothing to drain; report an idle quiescent quantum.
        return RunQuantumResult.new(
          queue_events_processed: 0, elapsed_seconds: 0.0,
          queue_depth: 0, max_queue_depth: 0, delayed_depth: 0,
          idle: true, budget_exhausted: budget_exhausted?,
        )
      end

      started = Time.instant
      deadline = started + max_seconds.seconds
      start_cursor = @dispatch_cursor
      max_queue_depth = 0
      dispatch_quantum(max_queue_events, deadline)
      depth = queue_depth
      max_queue_depth = {max_queue_depth, depth}.max

      exhausted = budget_exhausted?
      idle = !depth.positive? && @delayed.entries.empty?
      if exhausted || idle
        emit_idle_or_exhausted
      end

      RunQuantumResult.new(
        queue_events_processed: @dispatch_cursor - start_cursor,
        elapsed_seconds: (Time.instant - started).total_seconds,
        queue_depth: depth,
        max_queue_depth: max_queue_depth,
        delayed_depth: @delayed.entries.size,
        idle: idle,
        budget_exhausted: exhausted,
      )
    end

    # Number of undrained events (the dispatch cursor lags the store).
    private def queue_depth : Int32
      (@store.count - @dispatch_cursor).to_i32
    end

    # Drain up to `max_queue_events` pending events, stopping at the
    # deadline, without emitting an idle marker. One behavior invocation
    # remains atomic; the bound is checked between queue events.
    private def dispatch_quantum(max_queue_events : Int32, deadline : Time::Instant) : Nil
      graph = @graph
      return if graph.nil?

      processed = 0
      loop do
        break if budget_exhausted?
        break if Time.instant >= deadline
        break if processed >= max_queue_events

        events = @store.iter_events
        break if @dispatch_cursor >= events.size

        remaining = max_queue_events - processed
        end_index = Math.min(@dispatch_cursor + remaining, events.size)
        new_events = events[@dispatch_cursor...end_index]
        @dispatch_cursor = end_index
        break if new_events.empty?

        dispatch_new_events(new_events, graph)
        processed += new_events.size

        fire_due_delayed(events.last?.try(&.sequence) || 0u64)
      end
    end

    # Run the loop until the agent reaches a done step.
    def run_until_idle(prompt : String, caused_by : String? = nil) : String
      run(prompt, caused_by: caused_by)
    end

    # Events still available under the budget.
    def budget_remaining : Int64
      @budget.max_events - @store.count
    end

    def start_budget(max_events : Int64) : self
      @budget = Budget.new(max_events: max_events)
      self
    end

    def get_tool(name : String) : Tool?
      @tools.find { |tool| tool.name == name } ||
        @pack_tools.find { |tool| tool.name == name } ||
        resolve_pack_short_tool(name)
    end

    # Load a pack into this runtime. Idempotent on (name, version); raises
    # PackVersionConflictError / PackConflictError pre-mutation; records a
    # `pack.loaded` event. Returns true if newly loaded, false if a no-op.
    def load_pack(pack : Pack, settings : Hash(String, JSON::Any)? = nil, *, manifest_path : String? = nil) : Bool
      Packs::Loader.load_pack_into_runtime(self, pack, settings, manifest_path: manifest_path)
    end

    # Canonical settings for any loaded pack by name (Form 3 cross-pack lookup,
    # CONTRACT v0.9 #7), or nil if the pack isn't loaded. Ported from
    # activegraph.runtime.runtime.Runtime#pack_settings.
    def pack_settings(pack_name : String) : Hash(String, JSON::Any)?
      @pack_state.pack_settings[pack_name]?
    end

    # Structured warnings accumulated while loading packs (CONTRACT v1.6 #1 —
    # the manifest warning tier). Ported from upstream's manifest warning log.
    def pack_warnings : Array(String)
      @pack_warnings
    end

    protected def record_pack_warning(message : String) : Nil
      @pack_warnings << message
    end

    # Deregister a loaded pack: its behaviors stop firing NOW, tools stop
    # resolving, typed-object schemas and relation specs revert to untyped,
    # and gating policies are removed from this runtime's live registries.
    # Pack-created state stays (disabling code never rewrites history).
    # Emits `pack.disabled` with the deregistered surface. Idempotent: a
    # second disable returns false and emits nothing. Re-enable is `load_pack`
    # again (fresh load, not idempotent skip). Raises PackNotFoundError for a
    # name this runtime never loaded. Ported from
    # activegraph.runtime.runtime.Runtime#disable_pack (CONTRACT v1.4 #3).
    def disable_pack(name : String) : Bool
      state = @pack_state
      unless state.loaded_packs.has_key?(name)
        if state.disabled_packs.includes?(name)
          return false
        end
        raise Packs::PackNotFoundError.new(name, state.loaded_packs.keys)
      end

      pack = state.loaded_packs[name]
      state.loaded_packs.delete(name)
      state.pack_settings.delete(name)

      removed_behaviors = state.behavior_owners.keys.select { |canonical| state.behavior_owners[canonical] == name }.sort!
      removed_tools = state.tool_owners.keys.select { |canonical| state.tool_owners[canonical] == name }.sort!
      removed_object_types = state.object_type_owners.keys.select { |object_type| state.object_type_owners[object_type] == name }.sort!
      removed_relation_types = state.relation_type_owners.keys.select { |relation_type| state.relation_type_owners[relation_type] == name }.sort!

      removed_behaviors.each { |canonical| state.behavior_owners.delete(canonical) }
      removed_tools.each { |canonical| state.tool_owners.delete(canonical) }
      removed_object_types.each { |object_type| state.object_type_owners.delete(object_type); state.object_type_schemas.delete(object_type) }
      removed_relation_types.each { |relation_type| state.relation_type_owners.delete(relation_type); state.relation_type_specs.delete(relation_type) }
      state.policy_owners.keys.select { |canonical| state.policy_owners[canonical] == name }.each { |canonical| state.policy_owners.delete(canonical) }

      prefix = "#{name}."
      state.gated_object_types.keys.each do |object_type|
        remaining = state.gated_object_types[object_type].reject(&.starts_with?(prefix))
        if remaining.empty?
          state.gated_object_types.delete(object_type)
        else
          state.gated_object_types[object_type] = remaining
        end
      end

      # Short-name maps: recompute from the surviving canonicals — removal can
      # RESOLVE an ambiguity, not just delete entries.
      state.behavior_short_to_canonical.clear.merge!(rebuild_shorts(state.behavior_owners))
      state.tool_short_to_canonical.clear.merge!(rebuild_shorts(state.tool_owners))

      @pack_behaviors = @pack_behaviors.reject { |behavior| behavior.pack_owner == name }
      @pack_tools = @pack_tools.reject(&.name.starts_with?(prefix))

      state.disabled_packs.add(name)

      # Validators read state maps live; if the graph is attached, reinstall
      # them so the disabled pack's schemas stop enforcing (typed → untyped).
      if graph = @graph
        Packs::Loader.install_graph_validators(graph, state)
      end

      append_event("pack.disabled", JSON.build do |json|
        json.object do
          json.field "name", name
          json.field "version", pack.version
          json.field "behaviors" do
            json.array { removed_behaviors.each { |behavior_name| json.string(behavior_name) } }
          end
          json.field "tools" do
            json.array { removed_tools.each { |tool_name| json.string(tool_name) } }
          end
          json.field "object_types" do
            json.array { removed_object_types.each { |object_type| json.string(object_type) } }
          end
          json.field "relation_types" do
            json.array { removed_relation_types.each { |relation_type| json.string(relation_type) } }
          end
        end
      end)
      true
    end

    # Recompute a short-name map from the surviving canonical owners: a short
    # name maps to its canonical when unambiguous, AMBIGUOUS when two packs
    # claim it. Ported from activegraph's `_rebuild_shorts`.
    private def rebuild_shorts(owners : Hash(String, String)) : Hash(String, String)
      shorts = {} of String => String
      owners.each_key do |canonical|
        short = canonical.split(".", 2)[1]
        shorts[short] = shorts.has_key?(short) ? Packs::AMBIGUOUS : canonical
      end
      shorts
    end

    def pack_state : Packs::PackRuntimeState
      @pack_state
    end

    def pack_behaviors : Array(Packs::PackBehavior)
      @pack_behaviors
    end

    def pack_tools : Array(Tool)
      @pack_tools
    end

    def graph : GraphProjection?
      @graph
    end

    def llm_cache : LLMCache?
      @llm_cache
    end

    def loaded_packs : Array(String)
      @pack_state.loaded_packs.keys.sort!
    end

    def pack_policies : Array(Packs::PackPolicy)
      @pack_state.loaded_packs.values.flat_map(&.policies)
    end

    def tool_requires_approval?(tool_name : String) : Bool
      @tool_approval_policies.any?(&.requires_approval.includes?(tool_name))
    end

    # Look up a registered behavior by canonical or short name. Short names
    # resolve only when unambiguous; raises AmbiguousBehaviorError otherwise.
    def get_behavior(name : String) : Packs::PackBehavior
      if name.includes?('.')
        found = @pack_behaviors.find { |b| b.name == name }
        raise Packs::BehaviorNotFoundError.new(name) unless found
        return found
      end
      canonical = @pack_state.behavior_short_to_canonical[name]?
      if canonical.nil?
        raise Packs::BehaviorNotFoundError.new(name)
      end
      if canonical == Packs::AMBIGUOUS
        raise Packs::AmbiguousBehaviorError.new(
          "behavior name #{name.inspect} is ambiguous: it is provided by multiple loaded packs; use the fully-qualified name"
        )
      end
      found = @pack_behaviors.find { |b| b.name == canonical }
      raise Packs::BehaviorNotFoundError.new(name) unless found
      found
    end

    # Drain pack behaviors until no new events are produced. The no-prompt
    # form of run_until_idle: dispatches registered pack behaviors over new
    # events in the log, letting them mutate the attached graph. Mirrors
    # upstream `Runtime#run_until_idle`, which emits the idle marker (or a
    # budget-exhausted marker) once the log quiesces.
    def run_until_idle : Nil
      dispatch_pack_behaviors
      emit_idle_or_exhausted
    end

    # Drain pack behaviors until the predicate over the attached graph is
    # satisfied, the log quiesces, or the budget stops the loop, then record
    # the idle/budget marker. Ported from
    # activegraph.runtime.runtime.Runtime#run_until.
    def run_until(predicate : Proc(GraphProjection, Bool)) : Nil
      dispatch_pack_behaviors(stop_when: predicate)
      emit_idle_or_exhausted
    end

    # Pack-driven entry point: emit a `goal.created` event (actor `user` by
    # default) and run pack behaviors until the log quiesces. Ported from
    # activegraph.runtime.runtime.Runtime#run_goal.
    def run_goal(goal : String, *, actor : String = "user") : Nil
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "goal_created_#{next_seq}",
        type: "goal.created",
        actor: actor,
        caused_by: nil,
        frame_id: current_frame_id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object { json.field "goal", goal }
        end,
      )
      @store.append(event)
      run_until_idle
    end

    # Branch this run at `at_event` into an independent new run (CONTRACT
    # v0.5 #9). Requires a SQLite-backed store. Copies events up to and
    # including `at_event` into a fresh run_id, replays them into a new graph,
    # reseeds the graph's id counters, and returns a Runtime that continues
    # from the fork point. Forks-of-forks work the same way. Ported from
    # activegraph.runtime.runtime.Runtime#fork.
    def fork(at_event : String, label : String? = nil, *, replay_llm_cache : Bool = false, replay_tool_cache : Bool = false) : Runtime(M)
      store = @store
      unless store.is_a?(SQLiteEventStore)
        raise IncompatibleRuntimeState.new(
          "runtime.fork() requires a SQLite-backed runtime (current: #{store.class.name})"
        )
      end
      graph = @graph
      raise IncompatibleRuntimeState.new("runtime.fork() requires an attached graph") unless graph

      reject_mid_promote_block_fork(graph.events, at_event)

      new_run_id = graph.ids.run
      SQLiteEventStore.fork_run(
        path: store.db_path,
        parent_run_id: store.run_id,
        new_run_id: new_run_id,
        at_event_id: at_event,
        label: label,
        created_at: Time.utc.to_rfc3339,
      )
      fork_store = SQLiteEventStore.new(store.db_path, run_id: new_run_id)

      fork_events = fork_store.iter_events
      fork_graph = GraphProjection.replay(fork_events)
      fork_graph.attach_store(fork_store)
      fork_graph.ids.reseed_from_events(fork_events)

      fork_log = LogAgent(M).new(@log_agent.agent, store: fork_store, max_turns: 1)
      # Caches are populated from the PARENT's recorded llm.responded /
      # tool.responded events, not the fork's (which only contains events up to
      # and including at_event). A diverging fork that regenerates an identical
      # prompt hits the cache; a divergent prompt falls through to the provider
      # (CONTRACT v0.6 #8).
      fork_cache = replay_llm_cache ? LLMCache.from_events(@store.iter_events) : nil
      fork_tool_cache = replay_tool_cache ? ToolCache.from_events(@store.iter_events) : nil
      fork_rt = Runtime(M).new(
        store: fork_store, log_agent: fork_log, graph: fork_graph,
        run_id: new_run_id, llm_cache: fork_cache, tool_cache: fork_tool_cache,
      )
      fork_rt.inherit_pack_registrations(@pack_behaviors, @pack_state, @pack_tools)
      fork_rt.resume_from_idle(fork_events)
      fork_rt
    end

    # Re-open a stored run by `run_id` and return a Runtime wired to continue
    # from where the log left off (CONTRACT v0.5 #6). The caller supplies the
    # agent; the store and graph are rebuilt from the log. Ported from
    # activegraph.runtime.runtime.Runtime.load.
    def self.load(
      path : String,
      run_id : String,
      agent : Crig::Agent(M),
      *,
      max_turns : Int32 = 1,
    ) : Runtime(M)
      store = SQLiteEventStore.new(path, run_id: run_id)
      events = store.iter_events
      graph = GraphProjection.replay(events)
      graph.attach_store(store)
      graph.ids.reseed_from_events(events)
      log = LogAgent(M).new(agent, store: store, max_turns: max_turns)
      runtime = Runtime(M).new(store: store, log_agent: log, graph: graph, run_id: run_id)
      runtime.resume_from_idle(events)
      runtime
    end

    # Copy the parent's loaded-pack registrations into a freshly forked
    # runtime so it can continue dispatching the same pack behaviors.
    protected def inherit_pack_registrations(
      pack_behaviors : Array(Packs::PackBehavior),
      pack_state : Packs::PackRuntimeState,
      pack_tools : Array(Tool),
    ) : self
      @pack_behaviors = pack_behaviors
      @pack_state = pack_state.fork_snapshot
      @pack_tools = pack_tools
      self
    end

    # Seed the dispatch cursor past every event already drained by the last
    # `runtime.idle` marker (CONTRACT v0.5 diff #8). A fork/load must not
    # re-dispatch behaviors whose work already completed; only events emitted
    # after the last idle are candidates. Ported from activegraph's
    # `_requeue_unfired` high-water-mark rule.
    protected def resume_from_idle(events : Array(Event)) : self
      cursor = 0
      events.each_with_index do |event, index|
        cursor = index + 1 if event.type == "runtime.idle"
      end
      @dispatch_cursor = cursor
      self
    end

    # Raise when a fork cutoff would slice a promote block in half (CONTRACT
    # v1.3 #4). The cut is invalid iff any event after the cutoff is a
    # `promote:`-actor delta whose marker sits at or before the cutoff — the
    # child would inherit the marker without its full delta, breaking promote's
    # atomicity. Cutting before the marker (block fully excluded) or at the
    # block's last delta event (block fully included) is fine. Ported from
    # activegraph's `_reject_mid_promote_block_fork`.
    private def reject_mid_promote_block_fork(events : Array(Event), at_event : String) : Nil
      cut_index = events.index { |event| event.id == at_event }
      return if cut_index.nil? # unknown ids get EventNotFoundError downstream

      markers_before = Set(String).new
      events[0..cut_index].each do |event|
        markers_before << event.id if event.type == "promote.applied"
      end
      events[(cut_index + 1)..].each do |event|
        next unless event.actor.to_s.starts_with?("promote:")
        marker_id = event.caused_by
        next unless marker_id && markers_before.includes?(marker_id)
        raise IncompatibleRuntimeState.new(
          "fork(at_event=#{at_event.inspect}) would slice the promote block anchored at #{marker_id.inspect}: marker plus its quiescent delta events are one atomic unit"
        )
      end
    end

    # Apply `fork`'s net structural delta to this runtime (the parent).
    # Ported from activegraph.runtime.runtime.Runtime#promote (CONTRACT v1.3
    # #4). Three-way comparison against this run's state at the recorded fork
    # point: fork-only changes apply as ordinary parent events; both-sides
    # changes raise PromoteConflictError before any mutation (fail-closed,
    # atomic); this run's own post-fork work is left alone. Referential
    # integrity is part of the conflict check. Application is quiescent: delta
    # events append, project, and persist but do not fire behaviors — the
    # single reaction point is the `promote.applied` marker, emitted first,
    # then every delta event is `caused_by` it. Requires both runtimes on the
    # same SQLite store and `fork` to be a direct fork of this run per the
    # store's lineage records.
    def promote(fork : Runtime(M), *, dry_run : Bool = false) : PromotePlan | PromoteResult
      parent_store = @store
      unless parent_store.is_a?(SQLiteEventStore)
        raise IncompatibleRuntimeState.new("runtime.promote() requires a SQLite-backed receiver (got #{parent_store.class.name})")
      end
      fork_store = fork.store
      unless fork_store.is_a?(SQLiteEventStore)
        raise IncompatibleRuntimeState.new("runtime.promote() requires a SQLite-backed fork (got #{fork_store.class.name})")
      end

      parent_graph = graph
      fork_graph = fork.graph
      raise IncompatibleRuntimeState.new("runtime.promote() requires attached graphs") unless parent_graph && fork_graph

      if parent_store.db_path != fork_store.db_path
        raise PromoteLineageError.new("the runs live in different stores (#{parent_store.db_path.inspect} vs #{fork_store.db_path.inspect})")
      end

      record = fork_store.get_run
      if record.nil? || record.parent_run_id != self.run_id
        raise PromoteLineageError.new(
          "store records #{record.try(&.parent_run_id).inspect} as its parent, not #{self.run_id.inspect}"
        )
      end
      forked_at = record.forked_at_event_id
      raise PromoteLineageError.new("the store has no forked_at_event_id for this run") if forked_at.nil?

      warnings = Promote.promote_warnings(parent_store.iter_events, fork_store.iter_events, forked_at)
      plan = Promote.compute_promote_plan(
        parent_graph, fork_graph,
        from_run: fork.run_id, into_run: self.run_id,
        forked_at_event: forked_at, warnings: warnings,
      )

      return plan if dry_run
      unless plan.is_promotable
        raise PromoteConflictError.new(plan.conflicts)
      end

      validate_promote_schema(plan, parent_graph)

      # ---- apply (marker first, then the delta, quiescently) ----
      actor = "promote:#{fork.run_id}"
      frame_id = self.current_frame_id
      sequence = parent_graph.events.size.to_u64
      marker = parent_graph.emit(Event.new(
        schema_version: 1_u16,
        sequence: (sequence += 1_u64),
        id: parent_graph.ids.event,
        type: "promote.applied",
        actor: "runtime",
        caused_by: nil,
        frame_id: frame_id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "from_run", plan.from_run
            json.field "forked_at_event", plan.forked_at_event
            json.field "computed_against", plan.computed_against
            json.field "objects_created", plan.object_creates.map(&.["id"].as_s)
            json.field "objects_patched", plan.object_patches.map(&.["id"].as_s)
            json.field "objects_removed", plan.object_removes
            json.field "relations_created", plan.relation_creates.map(&.["id"].as_s)
            json.field "relations_removed", plan.relation_removes
            json.field "warnings", plan.warnings
          end
        end,
      ))
      emit_delta = ->(type : String, payload : String) {
        parent_graph.emit(Event.new(
          schema_version: 1_u16,
          sequence: (sequence += 1_u64),
          id: parent_graph.ids.event,
          type: type,
          actor: actor,
          caused_by: marker.id,
          frame_id: frame_id,
          timestamp: Time.utc,
          payload: payload,
        ))
      }

      applied = [] of String

      # Order: explicit relation removals first, then object removals, then
      # creates/patches, then relation creates.
      plan.relation_removes.each do |relation_id|
        applied << emit_delta.call("relation.removed", JSON.build { |j| j.object { j.field "id", relation_id } }).id
      end
      plan.object_removes.each do |object_id|
        applied << emit_delta.call("object.removed", JSON.build { |j| j.object { j.field "id", object_id } }).id
      end
      plan.object_creates.each do |entry|
        applied << emit_delta.call("object.created", JSON.build do |j|
          j.object do
            j.field "id", entry["id"].as_s
            j.field "type", entry["type"].as_s
            j.field "data" do
              j.raw(entry["data"].to_json)
            end
            j.field "version", 1
          end
        end).id
      end
      plan.object_patches.each do |entry|
        current = parent_graph.get_object(entry["id"].as_s)
        expected = current.try(&.version) || 0_i64
        applied << emit_delta.call("patch.applied", JSON.build do |j|
          j.object do
            j.field "patch" do
              j.object do
                j.field "id", parent_graph.ids.patch
                j.field "target", entry["id"].as_s
                j.field "op", "replace"
                j.field "value" do
                  j.raw(entry["data"].to_json)
                end
                j.field "expected_version", expected
                j.field "proposed_by", actor
              end
            end
            j.field "target", entry["id"].as_s
          end
        end).id
      end
      plan.relation_creates.each do |entry|
        applied << emit_delta.call("relation.created", JSON.build do |j|
          j.object do
            j.field "id", entry["id"].as_s
            j.field "type", entry["type"].as_s
            j.field "from_id", entry["source"].as_s
            j.field "to_id", entry["target"].as_s
          end
        end).id
      end

      # Promoted entities keep their fork-minted ids; bump this run's
      # generators past them so future mints can't collide.
      parent_graph.ids.reseed_from_events(parent_graph.events)

      PromoteResult.new(plan: plan, marker_event_id: marker.id, applied_event_ids: applied)
    end

    # Structural comparison of this run against `other` (typically a fork):
    # shared event prefix + each side's tail (lifecycle events filtered) plus
    # per-id divergent objects/relations. Ported from
    # activegraph.runtime.runtime.Runtime#diff (CONTRACT v0.5 #10).
    def diff(other : Runtime(M)) : Diff
      parent_graph = graph
      fork_graph = other.graph
      raise IncompatibleRuntimeState.new("runtime.diff() requires attached graphs") unless parent_graph && fork_graph

      Diff.compute(
        parent_graph, fork_graph,
        parent_events: self.store.iter_events,
        fork_events: other.store.iter_events,
        parent_run_id: self.run_id, fork_run_id: other.run_id,
      )
    end

    private def emit_idle_or_exhausted : Nil
      payload = JSON.build do |json|
        json.object do
          json.field "snapshot", %({"events":#{@store.count}})
        end
      end
      append_event(budget_exhausted? ? "runtime.budget_exhausted" : "runtime.idle", payload)
    end

    # Pre-mutation schema validation for a promote delta (CONTRACT v1.3 #4).
    # The delta is applied through hand-built events, which bypass add_object's
    # pack-schema hook — so validate here, against THIS runtime's loaded packs,
    # before anything mutates. Types no loaded pack declares pass through
    # untyped; typed data that violates the parent's schema raises
    # PackSchemaViolation with the parent byte-identical to before the call.
    # Validated (canonicalized) data replaces the raw delta payload. Ported
    # from activegraph.runtime.runtime.Runtime#promote.
    private def validate_promote_schema(plan : PromotePlan, parent_graph : GraphProjection) : Nil
      if obj_validator = parent_graph.pack_object_validator?
        (plan.object_creates + plan.object_patches).each do |entry|
          entry["data"] = JSON.parse(obj_validator.call(entry["type"].as_s, entry["data"].to_json))
        end
      end
      rel_validator = parent_graph.pack_relation_validator?
      return if rel_validator.nil?

      created_types = {} of String => String
      plan.object_creates.each { |entry| created_types[entry["id"].as_s] = entry["type"].as_s }
      endpoint_type = ->(object_id : String) {
        if created_types.has_key?(object_id)
          created_types[object_id]
        else
          parent_graph.get_object(object_id).try(&.type)
        end
      }
      plan.relation_creates.each do |entry|
        rel_validator.call(
          entry["type"].as_s,
          endpoint_type.call(entry["source"].as_s),
          endpoint_type.call(entry["target"].as_s),
        )
      end
    end

    # Deferred object creation behind a policy approval. Records the proposal
    # durably and returns the approval id (reused as the object id on approve).
    def propose_object(
      object_type : String,
      data : String,
      reason : String = "",
      caused_by : String? = nil,
    ) : String
      state = @pack_state
      gating = state.gated_object_types[object_type]? || [] of String
      owner_pack = gating.empty? ? "" : gating[0].split(".", 1)[0]
      n = state.next_approval_n
      state.next_approval_n = n + 1
      approval_id = "approval_%03d" % n
      approval = Packs::PackPendingApproval.new(
        id: approval_id, kind: "object", object_type: object_type,
        data: data, reason: reason, pack: owner_pack,
      )
      state.pack_pending_approvals << approval
      append_event("approval.proposed", JSON.build do |json|
        json.object do
          json.field "approval_id", approval_id
          json.field "kind", "object"
          json.field "object_type", object_type
          json.field "data" do
            json.raw(data)
          end
          json.field "reason", reason
          json.field "pack", owner_pack
          json.field "caused_by", caused_by
        end
      end)
      approval_id
    end

    def pack_pending_approvals : Array(Packs::PackPendingApproval)
      @pack_state.pack_pending_approvals
    end

    # Approve a pending pack approval and materialize the deferred object.
    def approve_pack(approval_id : String) : GraphObject
      list = @pack_state.pack_pending_approvals
      approval = list.find { |a| a.id == approval_id }
      raise ApprovalError.new("pack approval not found: #{approval_id}") unless approval
      list.delete(approval)
      graph = @graph
      raise ApprovalError.new("pack approval requires an attached graph") unless graph
      graph.add_object(approval.object_type, approval.data, actor: "runtime")
    end

    def current_frame_id : String?
      @frame_stack.current.try(&.id)
    end

    def push_frame(frame : Frame) : self
      @frame_stack.push(frame)
      self
    end

    def pop_frame : Frame
      @frame_stack.pop
    end

    def events_in_frame(frame_id : String) : Array(Event)
      @store.iter_events.select { |event| event.frame_id == frame_id }
    end

    def add_pending_approval(request : ApprovalRequest) : Nil
      @approvals.request(request)
    end

    def pending_approvals : Array(ApprovalRequest)
      @approvals.pending_requests
    end

    def approve(request_id : String) : ApprovalResult
      @approvals.resolve(ApprovalDecision.new(request_id, approved: true))
    end

    def authority_ceiling : String?
      @authority_ceiling
    end

    # ameba:disable Naming/AccessorMethodName
    def set_authority_ceiling(level : String) : self
      @authority_ceiling = level
      self
    end

    def evaluate_capability_authority(level : String) : Bool
      ceiling = @authority_ceiling
      return true if ceiling.nil?

      (AUTHORITY_RANKS[level]? || -1) <= (AUTHORITY_RANKS[ceiling]? || -1)
    end

    # Record and return one exact, run-local developer override receipt. The
    # event crosses normal store acceptance before this method returns;
    # promotion, event logging, and R4 governance authority are rejected before
    # emission. Ported from activegraph.runtime.runtime.Runtime#dev_override.
    def dev_override(
      *,
      actor : String,
      reason : String,
      target_gate : String,
      scope : String,
      resulting_authority : String,
    ) : DevOverride
      DevOverrideValidation.validate_override_request(
        actor: actor, reason: reason, target_gate: target_gate,
        scope: scope, resulting_authority: resulting_authority,
      )
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "dev_override_#{next_seq}",
        type: "dev.override",
        actor: actor,
        frame_id: current_frame_id,
        caused_by: nil,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "actor", actor
            json.field "reason", reason
            json.field "target_gate", target_gate
            json.field "scope", scope
            json.field "resulting_authority", resulting_authority
          end
        end,
      )
      @store.append(event)
      DevOverride.new(
        event_id: event.id, run_id: @run_id, actor: actor, reason: reason,
        target_gate: target_gate, scope: scope,
        resulting_authority: resulting_authority,
      )
    end

    # Reconstruct accepted developer override receipts from the log.
    def dev_overrides : Array(DevOverride)
      @store.iter_events.compact_map { |event| DevOverrideValidation.receipt_from_event(event, @run_id) }
    end

    # Validate an exact receipt for one local gate decision. No wildcard,
    # prefix, cross-run, promotion, event-log, or R4 match is possible. The
    # referenced event must still exist with identical fields.
    def validate_dev_override(
      receipt : DevOverride,
      *,
      target_gate : String,
      scope : String,
      required_authority : String,
    ) : Bool
      if receipt.run_id != @run_id || DevOverrideValidation.gate_forbidden?(target_gate)
        return false
      end
      if target_gate != receipt.target_gate || scope != receipt.scope
        return false
      end
      unless DevOverrideValidation.authority_allows?(receipt.resulting_authority, required_authority)
        return false
      end
      event = @store.get_event(receipt.event_id)
      return false unless event
      recorded = DevOverrideValidation.receipt_from_event(event, @run_id)
      recorded == receipt
    end

    # JSON trace export: the flat `events` list (in log order) plus a `frames`
    # object mapping each frame_id to its events, for grouped audit. The flat
    # list is preserved for backward compatibility; events without a frame_id
    # are not grouped.
    def export_trace : String
      events = @store.iter_events
      frames = {} of String => Array(Event)
      events.each do |event|
        if frame_id = event.frame_id
          (frames[frame_id] ||= [] of Event) << event
        end
      end
      JSON.build do |json|
        json.object do
          json.field "run_id", @run_id
          json.field "events" do
            json.array do
              events.each do |event|
                json.raw(event.canonical_json)
              end
            end
          end
          json.field "frames" do
            json.object do
              frames.each do |frame_id, frame_events|
                json.field frame_id do
                  json.array do
                    frame_events.each { |event| json.raw(event.canonical_json) }
                  end
                end
              end
            end
          end
        end
      end
    end

    # Frozen snapshot of the runtime (CONTRACT v0.8 #11). `state` is derived
    # from the log's most recent terminal marker (runtime.idle → idle,
    # runtime.budget_exhausted → exhausted, none → stopped), so a freshly
    # loaded runtime and the runtime that saved the log agree. `recent_events`
    # is the tail of id/type/actor/timestamp summaries; `registered_behaviors`
    # lists the loaded pack behaviors with their subscription surface. Ported
    # from activegraph.runtime.runtime.Runtime#status.
    def status : RuntimeStatus
      events = @store.iter_events
      state = RuntimeState::Stopped
      events.reverse_each do |event|
        if event.type == "runtime.budget_exhausted"
          state = RuntimeState::Exhausted
          break
        elsif event.type == "runtime.idle"
          state = RuntimeState::Idle
          break
        end
      end

      recent_events = events.last(20).map do |event|
        EventSummary.new(
          id: event.id, type: event.type,
          actor: event.actor, timestamp: event.timestamp.to_rfc3339,
        )
      end

      behaviors = @pack_behaviors.map do |behavior|
        BehaviorInfo.new(
          name: behavior.name,
          kind: behavior.kind.to_s.downcase,
          subscribed_to: behavior.event_types.dup,
          pattern: behavior.pattern,
          activate_after: behavior.activate_after,
        )
      end

      RuntimeStatus.new(
        run_id: @run_id, state: state, queue_depth: 0,
        events_processed: events.size.to_i64,
        budget: BudgetSnapshot.new(
          used: {} of String => Float64,
          limits: {"max_events" => @budget.max_events.to_f64.as(Float64?)},
          cost_used_usd: "0", cost_limit_usd: nil, exhausted_by: nil,
        ),
        frame: current_frame_id.try { |frame_id| FrameSnapshot.new(frame_id, nil) },
        registered_behaviors: behaviors,
        recent_events: recent_events,
      )
    end

    # Accumulated `behavior.failed` events as structured values (CONTRACT
    # v1.0.3 #3). Reads the store on each access — the events are the source
    # of truth and this is a projection. No caching, no listener
    # registration, no new state. Ported from
    # activegraph.runtime.runtime.Runtime#errors.
    def errors : Array(BehaviorFailure)
      @store.iter_events.compact_map do |event|
        next unless event.type == "behavior.failed"

        payload = JSON.parse(event.payload).as_h
        BehaviorFailure.new(
          behavior: payload["behavior"]?.try(&.as_s?) || "",
          event_id: payload["event_id"]?.try(&.as_s?) || "",
          reason: payload["reason"]?.try(&.as_s?),
          exception_type: payload["exception_type"]?.try(&.as_s?) || "",
          message: payload["message"]?.try(&.as_s?) || "",
          failed_event_id: event.id,
        )
      end
    rescue JSON::ParseException
      [] of BehaviorFailure
    end

    private def resolve_pack_short_tool(name : String) : Tool?
      canonical = @pack_state.tool_short_to_canonical[name]?
      return nil if canonical.nil? || canonical == Packs::AMBIGUOUS
      @pack_tools.find { |pack_tool| pack_tool.name == canonical }
    end

    # The durable `pack.loaded` event: full component manifest + canonical
    # settings. Mirrors activegraph.packs.loader._build_pack_loaded_payload.
    def record_pack_loaded(pack : Pack, settings_obj : Hash(String, JSON::Any)) : Event
      append_event("pack.loaded", JSON.build do |json|
        json.object do
          json.field "name", pack.name
          json.field "version", pack.version
          json.field "description", pack.description
          json.field "object_types" do
            json.array { pack.object_types.each { |object_type| json.string(object_type.name) } }
          end
          json.field "relation_types" do
            json.array { pack.relation_types.each { |relation_type| json.string(relation_type.name) } }
          end
          json.field "behaviors" do
            json.array { pack.behaviors.each { |b| json.string("#{pack.name}.#{b.name}") } }
          end
          json.field "tools" do
            json.array { pack.tools.each { |tool| json.string("#{pack.name}.#{tool.name}") } }
          end
          json.field "policies" do
            json.array { pack.policies.each { |policy| json.string("#{pack.name}.#{policy.name}") } }
          end
          json.field "prompts" do
            json.object do
              pack.prompt_manifest.each do |prompt_name, info|
                json.field prompt_name do
                  json.object do
                    json.field "version", info["version"]
                    json.field "hash", info["hash"]
                  end
                end
              end
            end
          end
          json.field "settings" do
            json.object do
              settings_obj.each do |key, value|
                json.field key do
                  json.raw(value.to_json)
                end
              end
            end
          end
          json.field "capabilities" do
            json.array do
              pack.capabilities.each do |capability|
                json.object do
                  json.field "provider", capability.provider
                  json.field "capability", capability.capability
                  json.field "risk_class", capability.risk_class
                  json.field "credential_ref", capability.credential_ref
                  unless capability.action_class.empty?
                    json.field "action_class", capability.action_class
                  end
                end
              end
            end
          end
        end
      end)
    end

    # Deterministic fan-out: process new log events through matching pack
    # behaviors until a pass produces no new events. Behaviors mutate the
    # attached graph, which appends to the same store.
    private def dispatch_pack_behaviors(*, stop_when : Proc(GraphProjection, Bool)? = nil) : Nil
      return if @pack_behaviors.empty?

      graph = @graph
      if graph.nil?
        raise GraphProjectionError.new("pack behavior dispatch requires an attached graph")
      end

      iterations = 0
      loop do
        if budget_exhausted?
          break
        end
        if predicate = stop_when
          break if predicate.call(graph)
        end
        events = @store.iter_events
        if @dispatch_cursor >= events.size
          break
        end

        new_events = events[@dispatch_cursor..]
        @dispatch_cursor = events.size
        break if new_events.empty?

        dispatch_new_events(new_events, graph)

        # Fire any `activate_after` entries whose dispatch window has arrived.
        # Chronicle derives the tick from the event sequence; graph mutations
        # that emit events (add_object) advance it, so entries become due as
        # later events dispatch.
        fire_due_delayed(events.last?.try(&.sequence) || 0u64)

        iterations += 1
        break if iterations >= 1000
      end
    end

    # Build the per-chunk dispatch list: behaviors with `activate_after` are
    # scheduled instead of invoked; the rest are invoked in deterministic
    # (sequence, -priority, name) order.
    private def dispatch_new_events(
      new_events : Array(Event),
      graph : GraphProjection,
    ) : Nil
      registry = Registry.new(@pack_behaviors)
      to_invoke = [] of {Event, RegistryMatch}
      new_events.each do |event|
        # Promote applies its delta quiescently (CONTRACT v1.3 #4): the
        # `promote:`-actor delta events project and persist but are never
        # matched to behaviors — the `promote.applied` marker is the only
        # reaction point and is dispatched normally.
        next if event.actor.to_s.starts_with?("promote:")
        registry.match(event, graph).each do |match|
          if after = match.behavior.activate_after
            schedule_delayed(match.behavior, event, after)
          else
            to_invoke << {event, match}
          end
        end
      end
      to_invoke.sort_by! { |entry| {entry[0].sequence, -entry[1].behavior.priority, entry[1].behavior.name} }
      to_invoke.each do |event, match|
        emit_pattern_matched(match, event) if match.behavior.pattern && !match.pattern_matches.empty?
        invoke_pack_behavior(match.behavior, event, graph, match.relations)
      end
    end

    # Emit a `pattern.matched` lifecycle marker so the trace shows the pattern
    # bindings for a pattern-based behavior that fired. Ported from
    # activegraph.runtime.runtime.Runtime#_emit_pattern_matched.
    private def emit_pattern_matched(match : RegistryMatch, event : Event) : Nil
      append_event("pattern.matched", JSON.build do |json|
        json.object do
          json.field "behavior", match.behavior.name
          json.field "event_id", event.id
          json.field "matches_count", match.pattern_matches.size
          json.field "pattern", match.behavior.pattern
        end
      end)
    end

    private def invoke_pack_behavior(
      behavior : Packs::PackBehavior,
      event : Event,
      graph : GraphProjection,
      relations : Array(GraphRelation) = [] of GraphRelation,
    ) : Nil
      owner = behavior.pack_owner || ""
      settings = @pack_state.pack_settings[owner]? || {} of String => JSON::Any
      provider = ->(name : String) : Hash(String, JSON::Any)? { @pack_state.pack_settings[name]? }
      ctx = Packs::BehaviorContext.new(owner, settings, provider)

      @metrics.counter("activegraph_behaviors_invoked_total", {"behavior" => behavior.name})
      t0 = Time.instant
      begin
        case behavior.kind
        in Packs::PackBehaviorKind::Behavior
          behavior.handler.try(&.call(event, graph, ctx))
        in Packs::PackBehaviorKind::Relation
          # Registry.match already selected the candidate relations referenced by
          # this event (upstream `_matching_relations`); invoke once per match.
          relations.each do |relation|
            behavior.relation_handler.try(&.call(relation, event, graph, ctx))
          end
        in Packs::PackBehaviorKind::LLM
          invoke_llm_behavior(behavior, event, ctx)
        end
      rescue error : Exception
        @metrics.counter("activegraph_behaviors_failed_total", {"behavior" => behavior.name, "reason" => error.class.to_s})
        # v1.0.3 #3: a failed behavior emits a durable behavior.failed event
        # (the Runtime#errors projection reads it) instead of propagating
        # out of dispatch — the run continues (upstream _invoke).
        record_behavior_failed(behavior, event, error)
      ensure
        @metrics.histogram("activegraph_behaviors_duration_seconds", {"behavior" => behavior.name}, (Time.instant - t0).total_seconds)
      end
    end

    # Emit `behavior.scheduled` and push a delayed-queue entry for a behavior
    # whose `activate_after=N` defers its invocation by N events. The fire
    # moment is derived from the triggering event's sequence (Chronicle's
    # dispatch tick).
    private def schedule_delayed(
      behavior : Packs::PackBehavior,
      event : Event,
      after : Int32,
    ) : Nil
      current = event.sequence
      sched = append_event("behavior.scheduled", JSON.build do |json|
        json.object do
          json.field "behavior", behavior.name
          json.field "event_id", event.id
          json.field "activate_after", after
          json.field "fire_at_tick", current + after
          json.field "current_tick", current
        end
      end)
      @delayed.push(Packs::ScheduledEntry.new(
        behavior_name: behavior.name,
        triggering_event_id: event.id,
        fire_at_sequence: current + after,
        scheduled_event_id: sched.id,
      ))
    end

    # Fire every `activate_after` entry whose fire window has arrived, after
    # re-checking `where=` against the triggering event's payload. A where
    # that no longer holds is skipped silently (CONTRACT v0.7 #13). Ported
    # from activegraph.runtime.runtime.Runtime#_fire_due_delayed.
    private def fire_due_delayed(current_sequence : UInt64) : Nil
      graph = @graph
      return if graph.nil?
      @delayed.pop_due(current_sequence).each do |entry|
        ev = @store.get_event(entry.triggering_event_id)
        next unless ev
        behavior = @pack_behaviors.find { |b| b.name == entry.behavior_name }
        next unless behavior
        if where = behavior.where
          next unless Packs.where_matches?(where, ev.payload)
        end
        next if behavior.kind == Packs::PackBehaviorKind::Relation
        invoke_pack_behavior(behavior, ev, graph)
      end
    end

    # Auto-run an `@[LLMBehavior]` handler against the recorded LLM effect
    # pipeline: emit `behavior.started`, compose the prompt, route through
    # `execute_model_request` (which records llm.requested / llm.responded and
    # honors the llm cache), invoke the handler with the model output, then
    # emit `behavior.completed`. Failures become a durable `behavior.failed`.
    private def invoke_llm_behavior(
      behavior : Packs::PackBehavior,
      event : Event,
      ctx : Packs::BehaviorContext,
    ) : Nil
      graph = @graph
      if graph.nil?
        raise GraphProjectionError.new("LLM behavior dispatch requires an attached graph")
      end
      record_behavior_started(behavior, event)
      objects_before = graph.all_objects.size
      relations_before = graph.all_relations.size

      begin
        if behavior.llm_handler.nil?
          raise Packs::PackError.new("LLM behavior #{behavior.name} is missing its handler")
        end
        output = execute_llm_behavior_request(behavior, event, ctx, graph)
        behavior.llm_handler.try(&.call(event, graph, ctx, output))
        record_behavior_completed(
          behavior, event, output,
          objects_created: graph.all_objects.size - objects_before,
          relations_created: graph.all_relations.size - relations_before,
        )
      rescue ex : Exception
        record_behavior_failed(behavior, event, ex)
      end
    end

    # Compose the LLM behavior prompt and run it through the same model effect
    # pipeline used by the agent loop (llm.requested -> execute -> llm.responded,
    # with cache and fallback). Returns the model output text.
    private def execute_llm_behavior_request(
      behavior : Packs::PackBehavior,
      event : Event,
      ctx : Packs::BehaviorContext,
      graph : GraphProjection,
    ) : String
      system = build_llm_system(behavior)
      user = build_llm_user_message(behavior, event, graph)
      payload = JSON.build do |json|
        json.object do
          json.field "behavior", behavior.name
          json.field "system", system
          json.field "user", user
          json.field "model", behavior.model.to_s
          json.field "max_tokens", behavior.max_tokens
          json.field "temperature", behavior.temperature
        end
      end

      effect = EffectRequest.new(
        "llm_behavior_#{next_seq}",
        EffectKind::Model,
        payload,
      )

      builder = Crig::Completion::Request::CompletionRequestBuilder.new(
        user
      )
      builder = builder
        .preamble(system)
        .model(behavior.model || "claude-sonnet-4-5")
        .temperature(behavior.temperature)
        .max_tokens(behavior.max_tokens.to_i64)

      response = execute_model_request(effect, builder.build, caused_by: event.id)
      response.choice.first.text.try(&.text) || ""
    end

    # System prompt: the behavior description composed with its (Optional)
    # named prompt body, mirroring upstream `_resolve_description`.
    private def build_llm_system(behavior : Packs::PackBehavior) : String
      parts = [] of String
      parts << behavior.description.strip unless behavior.description.empty?
      template = behavior.prompt_template
      parts << template.strip unless template.nil? || template.strip.empty?
      return "You are executing the #{behavior.name} behavior." if parts.empty?
      parts.join("\n\n")
    end

    # User message: the triggering event plus a bounded serialization of the
    # current graph so the model has context to act on.
    private def build_llm_user_message(
      behavior : Packs::PackBehavior,
      event : Event,
      graph : GraphProjection,
    ) : String
      String.build do |io|
        io << "## Triggering event\n"
        io << event.canonical_json
        io << "\n\n## Graph context\n"
        io << "{"
        graph.all_objects.each_with_index do |obj, index|
          io << ',' unless index == 0
          io << obj.id.to_json << ":{\"type\":" << obj.type.to_json << ",\"data\":"
          io << obj.data
          io << '}'
        end
        io << '}'
        io << "\n\nClassified by behavior: "
        io << behavior.name
      end
    end

    private def record_behavior_started(behavior : Packs::PackBehavior, event : Event) : Nil
      append_event("behavior.started", JSON.build do |json|
        json.object do
          json.field "behavior", behavior.name
          json.field "kind", behavior.kind.to_s
          json.field "trigger_event_id", event.id
        end
      end)
    end

    private def record_behavior_completed(
      behavior : Packs::PackBehavior,
      event : Event,
      output : String,
      *,
      objects_created : Int32 = 0,
      relations_created : Int32 = 0,
    ) : Nil
      append_event("behavior.completed", JSON.build do |json|
        json.object do
          json.field "behavior", behavior.name
          json.field "trigger_event_id", event.id
          json.field "objects_created", objects_created
          json.field "relations_created", relations_created
          json.field "output", output
        end
      end)
    end

    private def record_behavior_failed(behavior : Packs::PackBehavior, event : Event, error : Exception) : Nil
      append_event("behavior.failed", JSON.build do |json|
        json.object do
          json.field "behavior", behavior.name
          json.field "event_id", event.id
          json.field "trigger_event_id", event.id
          json.field "exception_type", error.class.to_s
          json.field "error_class", error.class.to_s
          json.field "message", error.message || error.class.to_s
          json.field "reason", error.is_a?(LLMBehaviorError) ? error.as(LLMBehaviorError).reason : nil
        end
      end)
    end

    private def drive_loop(user_message : Event, max_steps : Int32?) : Nil
      steps = 0
      loop do
        if budget_exhausted?
          record_budget_exhausted
          break
        end
        if max_steps && steps >= max_steps
          break
        end
        steps += 1
        step = @log_agent.next_step
        case step.kind
        in .call_model?
          drive_model(step)
        in .call_tools?
          drive_tools(step)
        in .done?
          if resp = step.response
            @response_text = resp.output
          end
          record_chat_message("assistant", @response_text, user_message.id)
          break
        end
      end
    end

    # Accept a channel command exactly once, then execute its durable goal.
    def handle(command : Channel::SendMessage) : Channel::Acknowledgement
      if accepted = accepted_command(command)
        return Channel::Acknowledgement.new(command.command_id, accepted.id, duplicate: true)
      end

      accepted = record_command_accepted(command)
      run(command.content, caused_by: accepted.id)
      Channel::Acknowledgement.new(command.command_id, accepted.id)
    end

    # Load a Runtime from an EventStore with recorded events.
    def self.load(
      store : EventStore,
      log_agent : LogAgent(M),
      policy : Routing::Policy? = nil,
      budget : Budget = Budget.new,
      replay_llm_cache : Bool = false,
      replay_strict : Bool = false,
      tools : Array(Tool) = [] of Tool,
      replay_tool_cache : Bool = false,
    ) : self
      cache = replay_llm_cache ? LLMCache.from_events(store.iter_events) : nil
      tool_cache = replay_tool_cache ? ToolCache.from_events(store.iter_events) : nil
      strict_hashes = if replay_strict
                        store.iter_events.select { |e| e.type == "llm.requested" }.map do |e|
                          JSON.parse(e.payload).as_h["request_hash"]?.try(&.as_s) || ""
                        end
                      end
      new(
        store: store, log_agent: log_agent, policy: policy, budget: budget,
        llm_cache: cache, strict_expected_hashes: strict_hashes,
        tools: tools, tool_cache: tool_cache,
      )
    end

    def decision : Routing::RouteDecision?
      @decision
    end

    def response : String
      @response_text
    end

    private def next_seq : UInt64
      (@store.count + 1).to_u64
    end

    private def accepted_command(command : Channel::SendMessage) : Event?
      @store.iter_events.find do |event|
        next false unless event.type == "command.accepted"

        payload = JSON.parse(event.payload).as_h
        payload["command_id"]?.try(&.as_s?) == command.command_id &&
          payload["run_id"]?.try(&.as_s?) == command.run_id
      end
    end

    private def record_command_accepted(command : Channel::SendMessage) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "command_accepted_#{next_seq}",
        type: "command.accepted",
        actor: "channel.#{command.channel}",
        caused_by: nil,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "command_id", command.command_id
            json.field "run_id", command.run_id
            json.field "channel", command.channel
            json.field "intent_hint", command.intent_hint
            json.field "model_override", command.model_override
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_routing_decision(decision : Routing::RouteDecision, caused_by : String) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "routing_decided_#{next_seq}",
        type: "routing.decided",
        actor: "runtime",
        caused_by: caused_by,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "intent", decision.intent.to_s
            json.field "classification" do
              json.object do
                json.field "matched_rule", decision.classification.matched_rule
                json.field "explicit", decision.classification.explicit?
                json.field "confidence", decision.classification.confidence
              end
            end
            json.field "provider", decision.target.provider
            json.field "model", decision.target.model
            json.field "eligible_targets" do
              json.array do
                decision.eligible_targets.each do |target|
                  json.object do
                    json.field "provider", target.provider
                    json.field "model", target.model
                  end
                end
              end
            end
            json.field "matched_rule", decision.matched_rule
            json.field "reason", decision.routing_reason
            json.field "override_used", decision.override_used?
            json.field "fallback_used", decision.fallback_used?
            json.field "included_context" do
              json.array { decision.included_context.each { |context| json.string(context.id) } }
            end
            json.field "excluded_context" do
              json.array do
                decision.excluded_context.each do |context|
                  json.object do
                    json.field "id", context.id
                    json.field "reason", context.reason
                  end
                end
              end
            end
            json.field "required_permissions" do
              json.object do
                decision.required_permissions.each do |name, permission|
                  json.field name, permission.to_s
                end
              end
            end
            json.field "estimated_cost" do
              json.object do
                json.field "minimum", decision.estimated_cost.minimum
                json.field "maximum", decision.estimated_cost.maximum
              end
            end
          end
        end,
      )
      @store.append(event)
      event
    end

    private def budget_exhausted? : Bool
      @store.count >= @budget.max_events
    end

    private def record_budget_exhausted : Nil
      evt = Event.new(
        schema_version: 1_u16, sequence: next_seq, id: "budget_exhausted",
        type: "budget.exhausted", actor: "runtime", caused_by: nil,
        timestamp: Time.utc, payload: %({"max_events":#{@budget.max_events}}),
      )
      @store.append(evt)
    end

    private def record_chat_message(role : String, content : String, caused_by : String?) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "chat_message_#{next_seq}",
        type: "chat.message",
        actor: role == "user" ? "user" : "agent",
        caused_by: caused_by,
        frame_id: current_frame_id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "role", role
            json.field "content", content
          end
        end,
      )
      @store.append(event)
      event
    end

    private def drive_model(step : Crig::AgentRunStep) : Nil
      return if budget_exhausted?
      effect = @log_agent.record_model_effect(step)
      return unless effect
      return if budget_exhausted?

      prompt = step.prompt
      history = step.history
      raise "model step is missing its prompt or history" unless prompt && history

      request = @log_agent.agent.build_completion_request(prompt, history).build
      response = execute_model_request(effect, request)
      turn = Crig::ModelTurn.new(
        message_id: "msg_#{next_seq}",
        choice: response.choice,
        usage: response.usage,
        allowed_tools: @tools.map(&.name),
      )
      @log_agent.model_response(turn, result_hash: effect.content_hash)
    end

    private def execute_model_request(
      effect : EffectRequest,
      request : Crig::Completion::Request::CompletionRequest,
      caused_by : String? = nil,
    )
      loop do
        target = current_execution_target || Routing::Target.new("legacy", "default", false)
        cached = @llm_cache.try(&.get(effect.content_hash))
        if hashes = @strict_expected_hashes
          assert_prompt_hash!(hashes, effect.content_hash)
        end
        request_event = record_llm_requested(effect, target, cache_hit: !cached.nil?, caused_by: caused_by)

        if cached_result = cached
          response = completion_response_from_cache(cached_result)
          record_llm_responded(request_event, target, response)
          return response
        end

        begin
          result = edge_worker.execute(ModelEffectInvocation.new(ModelEffectRequest.new(request_event.id, effect, target), request))
          response = Crig::Completion::CompletionResponse(String).new(
            result.choice,
            Crig::Completion::Usage.new(input_tokens: result.input_tokens, output_tokens: result.output_tokens),
            "",
            result.message_id,
          )
          record_llm_responded(request_event, target, response)
          @llm_cache.try(&.record(effect.content_hash, EffectResult.new(effect.content_hash, true, response_cache_payload(response))))
          return response
        rescue ex : Exception
          failed_event = record_llm_failed(request_event, target, ex)
          if ex.is_a?(RetryableProviderError)
            if select_next_fallback(failed_event)
              next
            else
              record_fallback_exhausted(failed_event)
            end
          end
          raise ex
        end
      end
    end

    private def assert_prompt_hash!(expected_hashes : Array(String), actual : String) : Nil
      expected = expected_hashes.shift? || ""
      if expected != actual
        raise ReplayDivergenceError.new(
          "replay diverged on prompt hash: expected prompt_hash=#{expected}, got prompt_hash=#{actual}"
        )
      end
    end

    private def completion_response_from_cache(result : EffectResult) : Crig::Completion::CompletionResponse(String)
      payload = JSON.parse(result.payload).as_h
      content = payload["content"]?.try(&.as_s) || ""
      input = payload["input_tokens"]?.try(&.as_i) || 0
      output = payload["output_tokens"]?.try(&.as_i) || 0
      choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text(content)
      )
      Crig::Completion::CompletionResponse(String).new(
        choice,
        Crig::Completion::Usage.new(input_tokens: input, output_tokens: output),
        "",
        payload["message_id"]?.try(&.as_s) || "cached",
      )
    end

    private def response_cache_payload(response) : String
      JSON.build do |json|
        json.object do
          json.field "content", response.choice.first.text.try(&.text)
          json.field "input_tokens", response.usage.input_tokens
          json.field "output_tokens", response.usage.output_tokens
          json.field "message_id", response.message_id
        end
      end
    end

    private def current_execution_target : Routing::Target?
      @execution_targets[@execution_target_index]? || @decision.try(&.target)
    end

    private def edge_worker : ModelEffectWorker
      if worker = @model_effect_worker
        return worker
      end
      ModelEffectWorker.new(FixedModelExecutor(M).new(@log_agent.agent.model))
    end

    private def select_next_fallback(caused_by : Event) : Bool
      next_index = @execution_target_index + 1
      target = @execution_targets[next_index]?
      return false unless target

      @execution_target_index = next_index
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "routing_fallback_selected_#{next_seq}",
        type: "routing.fallback_selected",
        actor: "runtime",
        caused_by: caused_by.id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "provider", target.provider
            json.field "model", target.model
          end
        end,
      )
      @store.append(event)
      true
    end

    private def record_fallback_exhausted(caused_by : Event) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "routing_fallback_exhausted_#{next_seq}",
        type: "routing.fallback_exhausted",
        actor: "runtime",
        caused_by: caused_by.id,
        timestamp: Time.utc,
        payload: %({"reason":"no recorded eligible fallback remains"}),
      )
      @store.append(event)
      event
    end

    private def record_llm_requested(
      effect : EffectRequest,
      target : Routing::Target?,
      cache_hit : Bool = false,
      caused_by : String? = nil,
    ) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "llm_requested_#{next_seq}",
        type: "llm.requested",
        actor: "runtime",
        caused_by: caused_by,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "request_hash", effect.content_hash
            json.field "prompt_hash", effect.content_hash
            json.field "provider", target.try(&.provider)
            json.field "model", target.try(&.model)
            json.field "cache_hit", cache_hit
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_llm_responded(
      request_event : Event,
      target : Routing::Target?,
      response,
    ) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "llm_responded_#{next_seq}",
        type: "llm.responded",
        actor: "provider",
        caused_by: request_event.id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "input_tokens", response.usage.input_tokens
            json.field "output_tokens", response.usage.output_tokens
            json.field "message_id", response.message_id
            json.field "provider", target.try(&.provider)
            json.field "model", target.try(&.model)
            json.field "content", response.choice.first.text.try(&.text)
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_llm_failed(
      request_event : Event,
      target : Routing::Target?,
      error : Exception,
    ) : Event
      event = Event.new(
        schema_version: 1_u16,
        sequence: next_seq,
        id: "llm_failed_#{next_seq}",
        type: "llm.failed",
        actor: "provider",
        caused_by: request_event.id,
        timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "error_class", error.class.to_s
            json.field "reason", safe_provider_failure_reason(error)
            json.field "retryable", error.is_a?(RetryableProviderError)
            json.field "provider", target.try(&.provider)
            json.field "model", target.try(&.model)
          end
        end,
      )
      @store.append(event)
      event
    end

    private def safe_provider_failure_reason(error : Exception) : String
      return "provider unavailable" if error.is_a?(ProviderNotAvailableError)
      "provider execution failed"
    end

    private def drive_tools(step : Crig::AgentRunStep) : Nil
      calls = step.calls
      return unless calls

      results = calls.map do |call|
        tc = call.tool_call
        name = tc.function.name
        args = tc.function.arguments.to_json
        output = invoke_tool(name, args)
        Crig::Completion::UserContent.tool_result(
          tc.id,
          Crig::OneOrMany(Crig::Completion::ToolResultContent).one(
            Crig::Completion::ToolResultContent.text(output)
          )
        )
      end
      @log_agent.tool_results(results)
    end

    private def invoke_tool(name : String, args : String) : String
      request_event = record_tool_requested(name, args)
      if cached = @tool_cache.try(&.get(name, args))
        record_tool_responded(request_event, name, args, cached)
        return cached
      end
      if tool_requires_approval?(name)
        add_pending_approval(ApprovalRequest.new("approval_#{next_seq}", ApprovalKind::Shell, "tool #{name}"))
        placeholder = %({"pending_approval":true,"tool":"#{name}"})
        record_tool_responded(request_event, name, args, placeholder)
        return placeholder
      end
      tool = @tools.find { |registered| registered.name == name }
      raise GraphProjectionError.new("unknown tool: #{name}") unless tool
      output = tool.call(args)
      record_tool_responded(request_event, name, args, output)
      @tool_cache.try(&.record(name, args, output))
      output
    end

    private def append_event(type : String, payload : String) : Event
      event = Event.new(
        schema_version: 1_u16, sequence: next_seq,
        id: "#{type.gsub(".", "_")}_#{next_seq}",
        type: type, actor: "runtime", caused_by: nil,
        frame_id: current_frame_id,
        timestamp: Time.utc, payload: payload,
      )
      @store.append(event)
      @metrics.counter("activegraph_events_emitted_total", {"event_type" => event.type})
      event
    end

    private def record_tool_requested(name : String, args : String) : Event
      event = Event.new(
        schema_version: 1_u16, sequence: next_seq,
        id: "tool_requested_#{next_seq}", type: "tool.requested",
        actor: "runtime", caused_by: nil, timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "tool", name
            json.field "args" do
              json.raw(args)
            end
          end
        end,
      )
      @store.append(event)
      event
    end

    private def record_tool_responded(request_event : Event, name : String, args : String, output : String) : Event
      event = Event.new(
        schema_version: 1_u16, sequence: next_seq,
        id: "tool_responded_#{next_seq}", type: "tool.responded",
        actor: "tool", caused_by: request_event.id, timestamp: Time.utc,
        payload: JSON.build do |json|
          json.object do
            json.field "tool", name
            json.field "args" do
              json.raw(args)
            end
            json.field "output" do
              json.raw(output)
            end
          end
        end,
      )
      @store.append(event)
      event
    end
  end
end
