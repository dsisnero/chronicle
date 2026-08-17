module Chronicle
  module Packs
    # The diligence reference pack — a runnable Crystal port of
    # activegraph.packs.diligence demonstrating the pack DSL end-to-end:
    # `@[ObjectType]` / `@[RelationType]` schemas, typed settings injection,
    # plain + `@[LLMBehavior]` + pattern-subscription behaviors, a pack-scoped
    # tool, and approval policies. Driven by a scripted/recorded provider (no
    # network); a production user would swap real tool bodies and providers.
    #
    # Flow: goal.created -> company_planner (company) -> question_generator
    # (LLM: questions) -> claim_extractor (LLM + tool: claims + evidence) ->
    # contradiction_detector (pattern: contradiction) -> memo_synthesizer
    # (LLM: memo behind the memo_approval policy).
    module Diligence
      include Chronicle::Packs::DSL

      # ------------------------------------------------------- settings

      struct Settings
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        property? auto_approve_memos : Bool = true
        property max_questions : Int32 = 5
        property max_claims_per_document : Int32 = 4
        property confidence_threshold_for_review : Float64 = 0.7
      end

      # ------------------------------------------------- object types

      @[ObjectType(name: "company", description: "Target company for a diligence run")]
      struct Company
        include JSON::Serializable
        property name : String
        property description : String = ""
      end

      @[ObjectType(name: "question")]
      struct Question
        include JSON::Serializable
        property text : String
        property company_id : String = ""
        property status : String = "open"
      end

      @[ObjectType(name: "claim")]
      struct Claim
        include JSON::Serializable
        property text : String
        property confidence : Float64
        property company_id : String = ""
        property source_document_id : String = ""
        property status : String = "open"
      end

      @[ObjectType(name: "evidence")]
      struct Evidence
        include JSON::Serializable
        property text : String
        property claim_id : String = ""
        property document_id : String = ""
      end

      @[ObjectType(name: "contradiction")]
      struct Contradiction
        include JSON::Serializable
        property claim_a_id : String
        property claim_b_id : String
        property rationale : String = ""
        property status : String = "open"
      end

      @[ObjectType(name: "memo")]
      struct Memo
        include JSON::Serializable
        property company_id : String = ""
        property summary : String = ""
        property thesis_questions_addressed : Array(JSON::Any) = [] of JSON::Any
        property key_claims : Array(JSON::Any) = [] of JSON::Any
        property open_contradictions : Array(JSON::Any) = [] of JSON::Any
        property risks : Array(JSON::Any) = [] of JSON::Any
        property contradictions_note : String = ""
      end

      # ------------------------------------------------ relation types

      @[RelationType(name: "addresses", source_types: ["claim"], target_types: ["question"])]
      struct AddressesRel; end

      @[RelationType(name: "supports", source_types: ["evidence"], target_types: ["claim"])]
      struct SupportsRel; end

      @[RelationType(name: "contradicts", source_types: ["claim"], target_types: ["claim"])]
      struct ContradictsRel; end

      # ---------------------------------------------------- behaviors

      @[Behavior(name: "company_planner", on: ["goal.created"])]
      def company_planner(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
        goal = JSON.parse(event.payload)["goal"].as_s
        return unless goal.starts_with?("Diligence:")

        name = goal["Diligence:".size..].strip
        graph.add_object("company", JSON.build do |json|
          json.object do
            json.field "name", name
            json.field "description", "Target company for diligence run: #{name}"
          end
        end)
      end

      struct QuestionList
        include JSON::Serializable
        property questions : Array(String)
      end

      @[LLMBehavior(name: "question_generator", on: ["object.created"],
        where: {"type" => "company"}, output_schema: QuestionList,
        description: "Generate research questions from the diligence thesis.")]
      def question_generator(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : QuestionList, settings : Settings)
        payload = JSON.parse(event.payload).as_h
        company_id = payload["id"].as_s
        data = payload["data"].as_h
        company_name = data["name"].as_s
        output.questions.first(settings.max_questions).each do |text|
          graph.add_object("question", JSON.build do |json|
            json.object do
              json.field "text", text
              json.field "company_id", company_id
              json.field "company_name", company_name
              json.field "status", "open"
            end
          end)
        end
      end

      struct ResearcherClaim
        include JSON::Serializable
        property text : String
        property confidence : Float64
        property evidence_quote : String = ""
        property contradicts_claim_text : String? = nil
      end

      struct ResearchFindings
        include JSON::Serializable
        property document_url : String
        property summary : String
        property claims : Array(ResearcherClaim)
      end

      @[LLMBehavior(name: "claim_extractor", on: ["object.created"],
        where: {"type" => "question"}, output_schema: ResearchFindings,
        tools: ["summarize_document"],
        description: "Extract claims with evidence from the company's documents.")]
      def claim_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : ResearchFindings, settings : Settings)
        payload = JSON.parse(event.payload).as_h
        question_id = payload["id"].as_s
        data = payload["data"].as_h
        company_id = data["company_id"].as_s

        doc_id = graph.add_object("document", JSON.build do |json|
          json.object do
            json.field "url", output.document_url
            json.field "summary", output.summary
            json.field "company_id", company_id
          end
        end).id

        text_to_claim = {} of String => String
        output.claims.first(settings.max_claims_per_document).each do |claim_out|
          claim = graph.add_object("claim", JSON.build do |json|
            json.object do
              json.field "text", claim_out.text
              json.field "confidence", claim_out.confidence
              json.field "company_id", company_id
              json.field "source_document_id", doc_id
              json.field "status", "open"
            end
          end)
          text_to_claim[claim_out.text] = claim.id
          graph.add_relation(claim.id, question_id, "addresses")
          if claim_out.evidence_quote
            ev = graph.add_object("evidence", JSON.build do |json|
              json.object do
                json.field "text", claim_out.evidence_quote
                json.field "claim_id", claim.id
                json.field "document_id", doc_id
              end
            end)
            graph.add_relation(ev.id, claim.id, "supports")
          end
          if target_text = claim_out.contradicts_claim_text
            if target = text_to_claim[target_text]?
              graph.add_relation(claim.id, target, "contradicts")
            end
          end
        end

        graph.patch_object(question_id, %({"status":"answered"}))
      end

      @[Behavior(name: "evidence_linker", on: ["object.created"], where: {"type" => "evidence"})]
      def evidence_linker(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
        payload = JSON.parse(event.payload).as_h
        evidence_id = payload["id"].as_s
        data = payload["data"].as_h
        claim_id = data["claim_id"]?.try(&.as_s)
        return if claim_id.nil? || graph.get_object(claim_id).nil?

        duplicate = graph.all_relations.any? { |relation| relation.type == "supports" && relation.from_id == evidence_id && relation.to_id == claim_id }
        graph.add_relation(evidence_id, claim_id, "supports") unless duplicate
      end

      @[Behavior(name: "contradiction_detector", on: ["relation.created"],
        where: {"type" => "contradicts"},
        pattern: "(c1:claim)-[r:contradicts]->(c2:claim) WHERE c1.confidence > 0.7 AND c2.confidence > 0.7")]
      def contradiction_detector(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : Settings)
        payload = JSON.parse(event.payload).as_h
        from_id = payload["from_id"].as_s
        to_id = payload["to_id"].as_s
        c1 = graph.get_object(from_id)
        c2 = graph.get_object(to_id)
        return if c1.nil? || c2.nil?

        threshold = settings.confidence_threshold_for_review
        c1_conf = JSON.parse(c1.data)["confidence"].as_f
        c2_conf = JSON.parse(c2.data)["confidence"].as_f
        return if Math.min(c1_conf, c2_conf) < threshold

        graph.add_object("contradiction", JSON.build do |json|
          json.object do
            json.field "claim_a_id", from_id
            json.field "claim_b_id", to_id
            json.field "rationale", "Both claims exceed the confidence threshold (#{threshold}) and assert conflicting facts. Surfaces for human review."
            json.field "status", "open"
          end
        end)
      end

      struct MemoBody
        include JSON::Serializable
        property summary : String
        property thesis_questions_addressed : Array(JSON::Any) = [] of JSON::Any
        property key_claims : Array(JSON::Any) = [] of JSON::Any
        property open_contradictions : Array(JSON::Any) = [] of JSON::Any
        property risks : Array(JSON::Any) = [] of JSON::Any
        property contradictions_note : String = ""
      end

      @[LLMBehavior(name: "memo_synthesizer", on: ["object.created"],
        where: {"type" => "contradiction"}, output_schema: MemoBody,
        description: "Synthesize the final diligence memo. The memo MUST have the contracted structure.")]
      def memo_synthesizer(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : MemoBody, settings : Settings)
        company = graph.all_objects.find { |obj| obj.type == "company" }
        return if company.nil?

        company_id = company.id
        return if graph.all_objects.any? { |obj| obj.type == "memo" && JSON.parse(obj.data)["company_id"].as_s == company_id }

        memo_payload = JSON.build do |json|
          json.object do
            json.field "company_id", company_id
            json.field "summary", output.summary
            json.field "thesis_questions_addressed", output.thesis_questions_addressed
            json.field "key_claims", output.key_claims
            json.field "open_contradictions", output.open_contradictions
            json.field "risks", output.risks
            json.field "contradictions_note", output.contradictions_note
          end
        end

        if settings.auto_approve_memos?
          graph.add_object("memo", memo_payload)
        else
          ctx.propose_object("memo", memo_payload, reason: "memo_approval policy: company #{company_id}")
        end
      end

      # --------------------------------------------------------- tools

      struct SummarizeDocumentInput
        getter url : String
        getter max_words : Int32

        def initialize(@url : String, @max_words : Int32 = 100)
        end
      end

      class_property summarize_body : Proc(String, String, String)? = nil

      @[Tool(name: "summarize_document", description: "Summarize a document at a given URL. Requires explicit live_unrecorded external-IO permission.")]
      def summarize_document(args : String, ctx : Chronicle::ToolContext) : String
        input = JSON.parse(args).as_h
        url = input["url"].as_s
        body = Diligence.summarize_body.try(&.call(url, "summarize"))
        JSON.build do |json|
          json.object do
            json.field "url", url
            json.field "summary", body || "fixture summary"
            json.field "external_io_mode", ctx.external_io_mode.to_s
          end
        end
      end

      # ---------------------------------------------------- pack export

      pack(
        name: "diligence",
        version: "0.1.0",
        description: "Investment diligence reference pack: claims, evidence, contradictions, risks, memos.",
        settings_schema: Settings,
        policies: [
          Chronicle::Packs::PackPolicy.new(name: "memo_approval", requires_approval: ["memo"]),
        ],
      )
    end
  end
end
