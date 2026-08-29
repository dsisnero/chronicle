require "crig"

module Chronicle
  # The quickstart onboarding demo (upstream cli/quickstart.py
  # run_fixture_mode): runs the diligence reference pack against a scripted
  # provider (no API key, no network) and returns the rendered transcript
  # lines. Sans-IO — the transcript is returned as `Array(String)`; the CLI /
  # caller writes it. The transcript shape (header, trace, memo, what-just-
  # happened, try-next) mirrors the upstream quickstart session.
  module Quickstart
    extend self

    # Scripted Crig provider whose canned responses drive the diligence flow
    # (question_generator -> claim_extractor x2 -> memo_synthesizer) — the
    # fixture-backed equivalent of upstream's RecordedDiligenceProvider.
    class ScriptedModel
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

    # Run the fixture-backed diligence demo and return the transcript lines.
    # Deterministic (scripted provider, fixed goal). Divergence: upstream runs
    # three fixture companies; the Chronicle demo runs one company (the memo
    # bar, trace, and prose are unchanged).
    def fixture_mode_lines : Array(String)
      lines = [] of String
      write = ->(s : String) : Nil { lines << s }

      model = ScriptedModel.new([
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

      store = Chronicle::MemoryEventStore.new
      graph = Chronicle::GraphProjection.empty.attach_store(store)
      agent = Crig::Agent(ScriptedModel).new(model: model, preamble: "")
      la = Chronicle::LogAgent(ScriptedModel).new(agent, store: store, max_turns: 1)
      worker = Chronicle::ModelEffectWorker.new(Chronicle::FixedModelExecutor(ScriptedModel).new(model))
      rt = Chronicle::Runtime(ScriptedModel).new(
        store: store, log_agent: la, graph: graph, model_effect_worker: worker,
      )
      rt.load_pack(Chronicle::Packs::Diligence::PACK)

      write.call("chronicle quickstart — running the bundled Diligence pack on a scripted provider.")
      write.call("")
      write.call("This takes a moment. No API key required.")
      write.call("  pack:       diligence v0.1.0  (no external network calls)")
      write.call("  companies:  Northwind Robotics")
      write.call("  provider:   ScriptedModel (fixture-backed)")
      write.call("")

      rt.run_goal("Diligence: Northwind Robotics")

      # Trace — canonical CONTRACT #18 lines from the event log. The
      # quickstart does not reformat; the trace printer is the contract.
      # ameba:disable Performance/ExcessiveAllocations
      Chronicle::TraceFacade.new(store).lines.each { |line| write.call(line) }
      write.call("")

      # Memo(s) — print the first in full, mention the others.
      memos = graph.all_objects.select { |obj| obj.type == "memo" }
      if memo = memos.first?
        Chronicle::Renderers.memo_section_lines(graph, memo).each { |line| write.call(line) }
        if memos.size > 1
          others = memos[1..].map { |memo_obj| Chronicle::Renderers.memo_company_name(graph, memo_obj) }
          write.call("Memos for #{others.join(", ")} were produced under the same contract.")
          write.call("")
        end
      end

      what_just_happened(write)
      try_next(write)
      lines
    end

    # The interactive command remains fixture-backed: one optional terminal
    # command can cancel the walkthrough, but it never opens a provider or
    # executes a tool. EOF completes the deterministic transcript.
    def interactive_lines(input : IO) : Array(String)
      lines = fixture_mode_lines
      case input.gets.try(&.strip.downcase)
      when "cancel", "quit", "exit"
        lines << "Quickstart cancelled. No provider or external tool was used."
      else
        lines << "Quickstart complete. No provider or external tool was used."
      end
      lines
    end

    private def what_just_happened(write : Proc(String, Nil)) : Nil
      rule = "-" * 76
      write.call(rule)
      write.call(" What just happened")
      write.call(rule)
      write.call("")
      write.call("  1. You loaded a pack. A pack is a Crystal module that registers")
      write.call("     object types, behaviors, tools, and prompts. The Diligence pack")
      write.call("     ships with chronicle.")
      write.call("")
      write.call("  2. The runtime received a goal and reactive behaviors fired")
      write.call("     automatically as objects appeared on the graph. You did not")
      write.call("     write a workflow. The behaviors are matched against event types")
      write.call("     and object shapes.")
      write.call("")
      write.call("  3. Every LLM call was served by the scripted fixture provider, so")
      write.call("     the run is deterministic and runs offline. Production runs")
      write.call("     against a real provider (via the Crig ModelExecutor seam) would")
      write.call("     show real costs and latencies.")
      write.call("")
      write.call("  4. Each memo cites evidence, surfaces at least one risk, and either")
      write.call("     lists open contradictions or states explicitly that none were")
      write.call("     found. This is the pack's \"verifiable memo bar\".")
      write.call("")
      write.call("  5. Every event is in the event log. The full causal chain from goal")
      write.call("     to memo is reconstructable from the log alone.")
      write.call("")
    end

    private def try_next(write : Proc(String, Nil)) : Nil
      rule = "-" * 76
      write.call(rule)
      write.call(" Try next")
      write.call(rule)
      write.call("")
      write.call("  See your run:        chronicle-cli trace --file <log> --object <id>")
      write.call("  Read the tutorial:   https://docs.activegraph.ai/quickstart")
      write.call("  Concept: behaviors:  https://docs.activegraph.ai/concepts/behaviors")
      write.call("")
    end
  end
end
