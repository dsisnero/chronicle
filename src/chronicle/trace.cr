require "json"

# Causal-chain audit. Ported from activegraph activegraph/trace/causal.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
# Walks back from an object through caused_by links until a goal.created
# (or an event with no parent).
module Chronicle
  module Trace
    extend self

    def causal_chain(events : Array(Event), graph : GraphProjection, object_id : String) : String
      obj = graph.get_object(object_id)
      return "(no such object: #{object_id})" if obj.nil?

      by_id = {} of String => Event
      events.each { |e| by_id[e.id] = e }

      created_by = events.find { |e| e.type == "object.created" && created_object?(e, object_id) }

      lines = ["#{obj.id} (#{obj.type})"]
      indent = "  "
      seen = Set(String).new
      cursor = created_by
      while cursor
        if seen.includes?(cursor.id)
          lines << "#{indent}← (cycle at #{cursor.id})"
          break
        end
        seen << cursor.id
        lines << "#{indent}← #{cursor.actor} (#{cursor.id}) #{cursor.type}"
        parent = cursor.caused_by
        break if parent.nil?

        cursor = by_id[parent]?
        indent += "  "
      end
      lines.join("\n")
    end

    private def created_object?(event : Event, object_id : String) : Bool
      payload = JSON.parse(event.payload).as_h
      payload["id"]?.try(&.as_s) == object_id
    rescue JSON::ParseException
      false
    end

    # --- CONTRACT #18 trace line rendering (format is the public contract).
    # Ported from activegraph.trace.printer. The tag column is left-aligned,
    # padded to TAG_COL chars; if the tag itself is longer, exactly one space
    # follows it. Chronicle stores flat payloads (object.created carries
    # id/type/data at top level), so the formatters read Chronicle's flat
    # shapes rather than upstream's nested object/relation dicts.

    TAG_COL = 26

    private def format_tag(tag_text : String) : String
      bracketed = "[#{tag_text}]"
      return bracketed + " " if bracketed.size >= TAG_COL
      bracketed.ljust(TAG_COL)
    end

    private def plural(n : Int32, word : String) : String
      "#{n} #{word}#{"s" if n != 1}"
    end

    private def money(value) : String
      value.to_s
    end

    private def short(value : JSON::Any) : String
      value.raw.is_a?(String) ? value.as_s : value.to_json
    end

    private def short_hash(value : JSON::Any?) : String
      return "?" unless value
      h = value.as_s?
      return value.to_json unless h
      h.size > 8 ? h[0, 8] : h
    end

    private def fmt_goal_created(payload : Hash(String, JSON::Any)) : String
      actor = "user"
      goal = payload["goal"]?.try(&.as_s) || ""
      "#{format_tag("goal.created")}#{actor}: \"#{goal}\""
    end

    private def fmt_object_created(payload : Hash(String, JSON::Any)) : String
      id = payload["id"]?.try(&.as_s) || "?"
      data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
      label = data["title"]?.try(&.as_s) || data["text"]?.try(&.as_s) || ""
      label_s = " \"#{label}\"" unless label.empty?
      status = data["status"]?.try(&.as_s)
      status_s = " (#{status})" if status
      "#{format_tag("object.created")}#{id}#{label_s}#{status_s}"
    end

    private def fmt_object_removed(payload : Hash(String, JSON::Any)) : String
      "#{format_tag("object.removed")}#{payload["id"]?.try(&.as_s) || "?"}"
    end

    private def fmt_relation_created(payload : Hash(String, JSON::Any)) : String
      source = payload["from_id"]?.try(&.as_s) || "?"
      target = payload["to_id"]?.try(&.as_s) || "?"
      type = payload["type"]?.try(&.as_s) || "?"
      "#{format_tag("relation.created")}#{source} --#{type}--> #{target}"
    end

    private def fmt_relation_removed(payload : Hash(String, JSON::Any)) : String
      "#{format_tag("relation.removed")}#{payload["id"]?.try(&.as_s) || "?"}"
    end

    private def fmt_patch_applied(payload : Hash(String, JSON::Any)) : String
      target = payload["target"]?.try(&.as_s) || "?"
      diff = payload["diff"]?.try(&.as_h)
      if diff.nil? || diff.empty?
        return "#{format_tag("patch.applied")}#{target} (no change)"
      end
      diff.map do |field, change|
        old = change["old"]?
        new = change["new"]?
        old_s = old.try { |v| short(v) } || "None"
        new_s = new.try { |v| short(v) } || "None"
        "#{format_tag("patch.applied")}#{target} #{field}: #{old_s} -> #{new_s}"
      end.join("\n")
    end

    private def fmt_patch_proposed(payload : Hash(String, JSON::Any)) : String
      p = payload["patch"]?.try(&.as_h)
      target = p && p["target"]?.try(&.as_s) || "?"
      op = p && p["op"]?.try(&.as_s) || "?"
      by = p && p["proposed_by"]?.try(&.as_s) || "?"
      "#{format_tag("patch.proposed")}#{target} #{op} by #{by}"
    end

    private def fmt_patch_rejected(payload : Hash(String, JSON::Any)) : String
      "#{format_tag("patch.rejected")}#{payload["patch_id"]?.try(&.as_s) || "?"}: #{payload["reason"]?.try(&.as_s) || "?"}"
    end

    private def fmt_promote_applied(payload : Hash(String, JSON::Any)) : String
      parts = [] of String
      n_created = (payload["objects_created"]?.try(&.as_a.size) || 0) +
                  (payload["relations_created"]?.try(&.as_a.size) || 0)
      n_patched = payload["objects_patched"]?.try(&.as_a.size) || 0
      n_removed = (payload["objects_removed"]?.try(&.as_a.size) || 0) +
                  (payload["relations_removed"]?.try(&.as_a.size) || 0)
      parts << "+#{n_created}" if n_created > 0
      parts << "~#{n_patched}" if n_patched > 0
      parts << "-#{n_removed}" if n_removed > 0
      counts = parts.empty? ? "empty delta" : parts.join(" ")
      "#{format_tag("promote.applied")}#{payload["from_run"]?.try(&.as_s) || "?"} -> here (#{counts}) forked_at=#{payload["forked_at_event"]?.try(&.as_s) || "?"}"
    end

    private def fmt_behavior_started(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      triggering_id = payload["triggering_object_id"]?.try(&.as_s?)
      if triggering_id
        "#{format_tag("behavior.started")}#{name}  (matched #{triggering_id})"
      else
        "#{format_tag("behavior.started")}#{name}"
      end
    end

    private def fmt_behavior_completed(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      n_obj = payload["objects_created"]?.try(&.as_i) || 0
      n_rel = payload["relations_created"]?.try(&.as_i) || 0
      if n_obj + n_rel >= 2
        "#{format_tag("behavior.completed")}#{name} (#{plural(n_obj, "object")}, #{plural(n_rel, "relation")})"
      else
        "#{format_tag("behavior.completed")}#{name}"
      end
    end

    private def fmt_behavior_failed(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      et = payload["exception_type"]?.try(&.as_s) || "?"
      msg = payload["message"]?.try(&.as_s) || ""
      "#{format_tag("behavior.failed")}#{name}: #{et}: #{msg}"
    end

    private def fmt_behavior_scheduled(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      n = payload["activate_after"]?.try(&.as_i) || 0
      id = payload["event_id"]?.try(&.as_s) || "?"
      "#{format_tag("behavior.scheduled")}#{id}  #{name}  activate_after=#{n}_event#{("s" if n != 1)}"
    end

    private def fmt_relation_behavior_started(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      triggering_type = payload["trigger_event_type"]?.try(&.as_s) || "?"
      relation_type = payload["relation_type"]?.try(&.as_s) || "?"
      "#{format_tag("relation_behavior.started")}#{name}  (matched #{triggering_type} on #{relation_type} edge)"
    end

    private def fmt_llm_requested(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      id = payload["event_id"]?.try(&.as_s) || "?"
      parts = ["#{id}  #{name}", "model=#{payload["model"]?.try(&.as_s) || "?"}"]
      if payload["cache_hit"]?.try(&.as_bool)
        parts << "cache_hit=true"
      end
      if payload["attempt_index"]?
        parts << "retry=#{payload["attempt_index"].try(&.as_i) + 1}/#{payload["max_attempts"]?.try(&.as_i) || 1}"
      end
      if payload["estimated_input_tokens"]?
        parts << "tokens_in~#{payload["estimated_input_tokens"].try(&.as_i)}"
      end
      if payload["budget_remaining_usd"]?
        parts << "budget_remaining=$#{money(payload["budget_remaining_usd"])}"
      end
      joined = parts[1..].join(" ")
      "#{format_tag("llm.requested")}#{parts[0]}  #{joined}"
    end

    private def fmt_llm_responded(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      id = payload["event_id"]?.try(&.as_s) || "?"
      parts = ["#{id}  #{name}"]
      if payload["cache_hit"]?.try(&.as_bool)
        parts << "cache_hit=true"
      end
      in_tok = payload["input_tokens"]?
      out_tok = payload["output_tokens"]?
      if in_tok
        parts << "tokens_in=#{in_tok.as_i}"
      end
      if out_tok
        parts << "tokens_out=#{out_tok.as_i}"
      end
      cost = payload["cost_usd"]?
      if cost && !payload["cache_hit"]?.try(&.as_bool)
        parts << "cost=$#{money(cost)}"
      end
      lat = payload["latency_seconds"]?
      if lat && !payload["cache_hit"]?.try(&.as_bool)
        parts << "latency=#{lat.as_f.round(1)}s"
      end
      "#{format_tag("llm.responded")}#{parts.join("  ")}"
    end

    private def fmt_tool_requested(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      id = payload["event_id"]?.try(&.as_s) || "?"
      tool = payload["tool"]?.try(&.as_s) || "?"
      parts = ["#{id}  #{name}", "tool=#{tool}", "args_hash=#{short_hash(payload["args_hash"]?)}"]
      parts << "cache_hit=true" if payload["cache_hit"]?.try(&.as_bool)
      "#{format_tag("tool.requested")}#{parts.join("  ")}"
    end

    private def fmt_tool_responded(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      id = payload["event_id"]?.try(&.as_s) || "?"
      tool = payload["tool"]?.try(&.as_s) || "?"
      parts = ["#{id}  #{name}", "tool=#{tool}"]
      parts << "cache_hit=true" if payload["cache_hit"]?.try(&.as_bool)
      lat = payload["latency_seconds"]?
      if lat && !payload["cache_hit"]?.try(&.as_bool)
        parts << "latency=#{lat.as_f.round(1)}s"
      end
      cost = payload["cost_usd"]?
      if cost && !payload["cache_hit"]?.try(&.as_bool)
        parts << "cost=$#{money(cost)}"
      end
      "#{format_tag("tool.responded")}#{parts.join("  ")}"
    end

    private def fmt_pattern_matched(payload : Hash(String, JSON::Any)) : String
      name = payload["behavior"]?.try(&.as_s) || "?"
      id = payload["event_id"]?.try(&.as_s) || "?"
      n = payload["matches_count"]?.try(&.as_i) || 0
      "#{format_tag("pattern.matched")}#{id}  #{name}  matches=#{n}"
    end

    private def fmt_runtime_idle : String
      "#{format_tag("runtime.idle")}queue empty, budget remaining"
    end

    private def fmt_pack_loaded(payload : Hash(String, JSON::Any)) : String
      name = payload["name"]?.try(&.as_s) || "?"
      version = payload["version"]?.try(&.as_s) || "?"
      counts = {
        "object_type"   => payload["object_types"]?.try(&.as_a.size) || 0,
        "relation_type" => payload["relation_types"]?.try(&.as_a.size) || 0,
        "behavior"      => payload["behaviors"]?.try(&.as_a.size) || 0,
        "tool"          => payload["tools"]?.try(&.as_a.size) || 0,
        "policy"        => payload["policies"]?.try(&.as_a.size) || 0,
        "prompt"        => payload["prompts"]?.try(&.as_h.size) || 0,
      }
      summary = counts.to_a.select { |pair| pair[1] > 0 }.map { |pair| plural(pair[1], pair[0]) }.join(", ")
      "#{format_tag("pack.loaded")}#{name} v#{version} (#{summary})"
    end

    private def fmt_runtime_budget_exhausted(payload : Hash(String, JSON::Any)) : String
      by = payload["exhausted_by"]?.try(&.as_s) || "?"
      "#{format_tag("runtime.budget_exhausted")}stopped: #{by}"
    end

    private def fmt_event_emitted(event : Event, payload : Hash(String, JSON::Any)) : String
      kvs = payload.map { |k, v| "#{k}=#{short(v)}" }
      body = ([event.type] + kvs).join(" ")
      "#{format_tag("event.emitted")}#{body}"
    end

    # Render one event as a CONTRACT #18 trace line. Ported from
    # activegraph.trace.printer.format_event (which dispatches through its
    # `_FORMATTERS` table).
    def format_event(event : Event) : String
      payload = JSON.parse(event.payload).as_h
      formatter = FORMATTERS[event.type]?
      if formatter
        formatter.call(payload)
      elsif event.type == "runtime.idle"
        fmt_runtime_idle
      else
        fmt_event_emitted(event, payload)
      end
    rescue JSON::ParseException
      "#{format_tag("event.emitted")}#{event.type}"
    end

    FORMATTERS = {
      "goal.created"              => ->(p : Hash(String, JSON::Any)) { fmt_goal_created(p) },
      "object.created"            => ->(p : Hash(String, JSON::Any)) { fmt_object_created(p) },
      "object.removed"            => ->(p : Hash(String, JSON::Any)) { fmt_object_removed(p) },
      "relation.created"          => ->(p : Hash(String, JSON::Any)) { fmt_relation_created(p) },
      "relation.removed"          => ->(p : Hash(String, JSON::Any)) { fmt_relation_removed(p) },
      "patch.applied"             => ->(p : Hash(String, JSON::Any)) { fmt_patch_applied(p) },
      "patch.proposed"            => ->(p : Hash(String, JSON::Any)) { fmt_patch_proposed(p) },
      "patch.rejected"            => ->(p : Hash(String, JSON::Any)) { fmt_patch_rejected(p) },
      "promote.applied"           => ->(p : Hash(String, JSON::Any)) { fmt_promote_applied(p) },
      "behavior.started"          => ->(p : Hash(String, JSON::Any)) { fmt_behavior_started(p) },
      "behavior.completed"        => ->(p : Hash(String, JSON::Any)) { fmt_behavior_completed(p) },
      "behavior.failed"           => ->(p : Hash(String, JSON::Any)) { fmt_behavior_failed(p) },
      "behavior.scheduled"        => ->(p : Hash(String, JSON::Any)) { fmt_behavior_scheduled(p) },
      "relation_behavior.started" => ->(p : Hash(String, JSON::Any)) { fmt_relation_behavior_started(p) },
      "llm.requested"             => ->(p : Hash(String, JSON::Any)) { fmt_llm_requested(p) },
      "llm.responded"             => ->(p : Hash(String, JSON::Any)) { fmt_llm_responded(p) },
      "tool.requested"            => ->(p : Hash(String, JSON::Any)) { fmt_tool_requested(p) },
      "tool.responded"            => ->(p : Hash(String, JSON::Any)) { fmt_tool_responded(p) },
      "pattern.matched"           => ->(p : Hash(String, JSON::Any)) { fmt_pattern_matched(p) },
      "runtime.budget_exhausted"  => ->(p : Hash(String, JSON::Any)) { fmt_runtime_budget_exhausted(p) },
      "pack.loaded"               => ->(p : Hash(String, JSON::Any)) { fmt_pack_loaded(p) },
    } of String => Proc(Hash(String, JSON::Any), String)

    # --- replay rendering (CONTRACT v0.5 #22) -----------------------------

    # Render a replayed event with the `[replay.event]` prefix. Chronicle
    # stores flat payloads, so object/relation ids are read at top level.
    def format_replay(event : Event) : String
      payload = JSON.parse(event.payload).as_h
      formatter = REPLAY_FORMATTERS[event.type]?
      body = formatter ? formatter.call(event, payload) : "#{event.id} #{event.type}"
      "#{format_tag("replay.event")}#{body}"
    rescue JSON::ParseException
      "#{format_tag("replay.event")}#{event.id} #{event.type}"
    end

    private def replay_body_object_created(event : Event, p : Hash(String, JSON::Any)) : String
      oid = p["id"]?.try(&.as_s) || "?"
      data = p["data"]?.try(&.as_h) || {} of String => JSON::Any
      label = data["title"]?.try(&.as_s) || data["text"]?.try(&.as_s) || ""
      label_s = " \"#{label}\"" unless label.empty?
      "#{event.id} #{event.type} #{oid}#{label_s}"
    end

    private def replay_body_relation_created(event : Event, p : Hash(String, JSON::Any)) : String
      source = p["from_id"]?.try(&.as_s) || "?"
      target = p["to_id"]?.try(&.as_s) || "?"
      "#{event.id} #{event.type} #{source} --#{p["type"]?.try(&.as_s) || "?"}--> #{target}"
    end

    private def replay_body_patch_applied(event : Event, p : Hash(String, JSON::Any)) : String
      "#{event.id} #{event.type} #{p["target"]?.try(&.as_s) || "?"}"
    end

    private def replay_body_goal_created(event : Event, p : Hash(String, JSON::Any)) : String
      "#{event.id} #{event.type} \"#{p["goal"]?.try(&.as_s) || ""}\""
    end

    private def replay_body_behavior(event : Event, p : Hash(String, JSON::Any)) : String
      "#{event.id} #{event.type} #{p["behavior"]?.try(&.as_s) || "?"}"
    end

    private def replay_body_promote_applied(event : Event, p : Hash(String, JSON::Any)) : String
      n = (p["objects_created"]?.try(&.as_a.size) || 0) +
          (p["objects_patched"]?.try(&.as_a.size) || 0) +
          (p["objects_removed"]?.try(&.as_a.size) || 0) +
          (p["relations_created"]?.try(&.as_a.size) || 0) +
          (p["relations_removed"]?.try(&.as_a.size) || 0)
      "#{event.id} #{event.type} from #{p["from_run"]?.try(&.as_s) || "?"} (#{plural(n, "delta event")})"
    end

    REPLAY_FORMATTERS = {
      "object.created"            => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_object_created(e, p) },
      "relation.created"          => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_relation_created(e, p) },
      "patch.applied"             => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_patch_applied(e, p) },
      "goal.created"              => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_goal_created(e, p) },
      "behavior.started"          => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_behavior(e, p) },
      "behavior.completed"        => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_behavior(e, p) },
      "behavior.failed"           => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_behavior(e, p) },
      "relation_behavior.started" => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_behavior(e, p) },
      "promote.applied"           => ->(e : Event, p : Hash(String, JSON::Any)) { replay_body_promote_applied(e, p) },
    } of String => Proc(Event, Hash(String, JSON::Any), String)

    def format_replay_complete(n : Int32) : String
      "#{format_tag("replay.complete")}#{n} events replayed, graph reconstructed"
    end

    def format_replay_ready : String
      "#{format_tag("runtime.idle")}ready to resume"
    end

    # Rollup for the v0.9.1 prompt_normalized trace flag. Returns a tuple of
    # `{true, count}` if every non-replayed `llm.requested` event carries
    # `prompt_normalized=true`, else nil (mixed flags keep the per-line
    # rendering). Chronicle's llm.requested records prompt_hash rather than
    # prompt_normalized, so this is a faithful no-op today — retained for
    # parity with the upstream trace contract.
    def prompt_normalized_rollup(events : Array(Event), replayed_ids : Set(String)) : {Bool, Int32}?
      llm_reqs = events.select { |e| e.type == "llm.requested" && !replayed_ids.includes?(e.id) }
      return nil if llm_reqs.empty?
      llm_reqs.each do |e|
        payload = JSON.parse(e.payload).as_h
        return nil unless payload["prompt_normalized"]?.try(&.as_bool)
      rescue JSON::ParseException
        return nil
      end
      {true, llm_reqs.size}
    end

    def format_trace_flags(count : Int32) : String
      "#{format_tag("trace.flags")}prompt_normalized=true (#{plural(count, "llm request")})"
    end
  end

  # Read-only facade over a run's event log, exposed as `runtime.trace`
  # (v1.3 structured accessors). `events` returns the run's events in log
  # order (a copy — each carries the id `Runtime#fork`'s `at_event=` expects);
  # `failures` returns the `behavior.failed` events whose payloads carry
  # behavior/event_id/exception_type/message/traceback. Ported from
  # activegraph.trace.printer.Trace (named TraceFacade because Chronicle's
  # `Trace` module already owns causal_chain).
  class TraceFacade
    @store : EventStore

    def initialize(@store : EventStore)
    end

    # The run's events, in log order, as Event objects. A copy — mutating
    # the returned list changes nothing.
    def events : Array(Event)
      @store.iter_events.dup
    end

    # The run's `behavior.failed` events, in log order. Each payload carries
    # behavior, event_id, exception_type, message, and the full traceback.
    def failures : Array(Event)
      @store.iter_events.select { |event| event.type == "behavior.failed" }
    end

    # The CONTRACT #18 trace lines for the run, in log order. Replayed events
    # render with the `[replay.event]` prefix (CONTRACT v0.5 #22) followed by
    # a single `[replay.complete]` + `[runtime.idle] ready to resume`
    # boundary. Ported from activegraph.trace.printer.Trace.lines.
    def lines(replayed_ids : Set(String) = Set(String).new) : Array(String)
      events = @store.iter_events
      replayed_count = replayed_ids.size
      rollup = Chronicle::Trace.prompt_normalized_rollup(events, replayed_ids)
      out = [] of String
      emitted_boundary = false
      emitted_flags = false
      events.each do |event|
        if replayed_ids.includes?(event.id)
          out << Chronicle::Trace.format_replay(event)
          next
        end
        if replayed_count > 0 && !emitted_boundary
          out << Chronicle::Trace.format_replay_complete(replayed_count)
          out << Chronicle::Trace.format_replay_ready
          emitted_boundary = true
        end
        if rollup && !emitted_flags
          out << Chronicle::Trace.format_trace_flags(rollup[1])
          emitted_flags = true
        end
        out << Chronicle::Trace.format_event(event)
      end
      if replayed_count > 0 && !emitted_boundary
        out << Chronicle::Trace.format_replay_complete(replayed_count)
        out << Chronicle::Trace.format_replay_ready
      end
      out
    end
  end
end
