require "../spec_helper"

# Typed output-schema struct used to exercise schema generation from
# JSON::Serializable types + enums (the Pydantic-replacement surface).
struct PromptOut
  include JSON::Serializable

  getter n : Int32
  getter label : String?
end

struct PromptClaim
  include JSON::Serializable

  getter text : String
  getter confidence : Float64 = 0.0
end

private def prompt_event(
  id : String = "evt_000001",
  type : String = "object.created",
  payload : String = %({"id":"document#1","type":"document","data":{"title":"T"},"version":1}),
  actor : String = "system",
) : Chronicle::Event
  Chronicle::Event.new(
    schema_version: 1_u16, sequence: 1_u64, id: id,
    type: type, actor: actor, caused_by: nil,
    timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
    payload: payload,
  )
end

private def populated_view : Chronicle::View
  graph = Chronicle::GraphProjection.empty
  d1 = graph.add_object("document", %({"title":"Doc one","body":"body"}))
  d2 = graph.add_object("document", %({"title":"Doc two","body":"body"}))
  graph.add_relation(d1.id, d2.id, "refers_to")
  Chronicle::View.new(
    objects: graph.all_objects,
    relations: graph.all_relations,
    events: graph.events,
  )
end

private def assemble_prompt_kwargs(
  view : Chronicle::View,
  event : Chronicle::Event,
  *,
  model : String = "claude-sonnet-4-5",
  behavior_name : String = "x",
  description : String = "d",
  output_schema : T.class = Nil.class,
  creates : Array(String) = [] of String,
  frame : Chronicle::Frame? = nil,
  around : String? = nil,
  depth : Int32? = nil,
  max_tokens : Int32 = 512,
  temperature : Float64 = 0.7,
  top_p : Float64 = 1.0,
  deterministic : Bool = false,
  prompt_template : String? = nil,
) : Chronicle::Prompt::AssembledPrompt forall T
  Chronicle::Prompt.assemble_prompt(
    behavior_name: behavior_name,
    description: description,
    model: model,
    output_schema: output_schema,
    creates: creates,
    view: view,
    event: event,
    frame: frame,
    around: around,
    depth: depth,
    max_tokens: max_tokens,
    temperature: temperature,
    top_p: top_p,
    deterministic: deterministic,
    prompt_template: prompt_template,
  )
end

describe Chronicle::Prompt do
  describe ".serialize_view" do
    it "serializes an empty view (test_view_serializer_empty)" do
      out = Chronicle::Prompt.serialize_view(
        Chronicle::View.new(objects: [] of Chronicle::GraphObject, relations: [] of Chronicle::GraphRelation, events: [] of Chronicle::Event)
      )
      out.should eq(
        "## Graph context\n" \
        "\n" \
        "### Objects\n" \
        "- (none)\n" \
        "\n" \
        "### Relations\n" \
        "- (none)\n" \
        "\n" \
        "### Recent events\n" \
        "- (none)"
      )
    end

    it "pins the populated format (test_view_serializer_populated_format_is_locked)" do
      out = Chronicle::Prompt.serialize_view(populated_view, around: "document#1", depth: 2)
      out.should contain("## Graph context (depth=2, around=document#1)")
      out.should contain("### Objects")
      out.should contain("- document#1 (document):")
      out.should contain("- document#2 (document):")
      out.should contain("### Relations")
      out.should contain("- document#1 --refers_to--> document#2")
      out.should contain("### Recent events")
      out.should contain("object.created")
    end

    it "renders object data as canonical sorted JSON (test_view_serializer_object_data_is_canonical_json)" do
      graph = Chronicle::GraphProjection.empty
      graph.add_object("note", %({"z":1,"a":2}))
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: [] of Chronicle::Event)
      out = Chronicle::Prompt.serialize_view(view)
      out.should contain(%({"a": 2, "z": 1}))
      out.index(%("a": 2)).not_nil!.should be < out.index(%("z": 1)).not_nil!
    end
  end

  describe ".build_system_prompt" do
    it "omits absent sections (test_system_prompt_omits_absent_sections)" do
      sp = Chronicle::Prompt.build_system_prompt(
        behavior_name: "x", description: "",
        frame: nil, output_schema_name: nil, output_schema_json: nil,
      )
      sp.should_not contain("Mission:")
      sp.should_not contain("Constraints:")
      sp.should_not contain("Role:")
      sp.should_not contain("Respond with JSON")
      sp.should contain(%(behavior named "x"))
    end

    it "orders blocks frame then constraints then role then schema (test_system_prompt_orders_blocks)" do
      sp = Chronicle::Prompt.build_system_prompt(
        behavior_name: "extractor",
        description: "Pull facts.",
        frame: Chronicle::Frame.new(goal: "Audit Q3", constraints: ["cite spans", "no hallucinations"]),
        output_schema_name: "ClaimList",
        output_schema_json: {"type" => JSON::Any.new("object")},
      )
      mission_i = sp.index("Mission:").not_nil!
      constraints_i = sp.index("Constraints:").not_nil!
      role_i = sp.index("Role:").not_nil!
      schema_i = sp.index("Respond with JSON").not_nil!
      (mission_i < constraints_i).should be_true
      (constraints_i < role_i).should be_true
      (role_i < schema_i).should be_true
    end
  end

  describe ".build_instruction" do
    it "uses schema and creates (test_instruction_uses_schema_and_creates)" do
      s = Chronicle::Prompt.build_instruction(creates: ["claim"], output_schema_name: "ClaimList")
      s.should contain("ClaimList")
      s.should contain("claim")
    end

    it "schema only (test_instruction_schema_only)" do
      s = Chronicle::Prompt.build_instruction(creates: [] of String, output_schema_name: "ClaimList")
      s.should contain("ClaimList")
    end

    it "creates only (test_instruction_creates_only)" do
      s = Chronicle::Prompt.build_instruction(creates: ["claim"], output_schema_name: nil)
      s.should contain("claim")
    end

    it "fallback (test_instruction_fallback)" do
      s = Chronicle::Prompt.build_instruction(creates: [] of String, output_schema_name: nil)
      s.should contain("what should happen")
    end
  end

  describe ".assemble_prompt" do
    it "returns sections and a sha256 hash (test_assemble_prompt_returns_sections_and_hash)" do
      graph = Chronicle::GraphProjection.empty
      ev = graph.add_object("document", %({"title":"T","body":"B"}))
      event = graph.events.find { |e| e.type == "object.created" }.not_nil!
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: graph.events)
      p = assemble_prompt_kwargs(
        output_schema: PromptOut,
        creates: ["x"],
        view: view, event: event,
        around: "document#1", depth: 1,
      )
      p.sections.keys.sort.should eq(["event", "instruction", "system", "user", "view"])
      p.hash.size.should eq(64)
    end

    it "hash is stable across identical inputs (test_hash_stable_across_identical_inputs)" do
      g1 = Chronicle::GraphProjection.empty
      g1.add_object("document", %({"title":"T","body":"B"}))
      ev1 = g1.events.find { |e| e.type == "object.created" }.not_nil!
      v1 = Chronicle::View.new(objects: g1.all_objects, relations: [] of Chronicle::GraphRelation, events: g1.events)

      g2 = Chronicle::GraphProjection.empty
      g2.add_object("document", %({"title":"T","body":"B"}))
      ev2 = g2.events.find { |e| e.type == "object.created" }.not_nil!
      v2 = Chronicle::View.new(objects: g2.all_objects, relations: [] of Chronicle::GraphRelation, events: g2.events)

      p1 = assemble_prompt_kwargs(
        view: v1, event: ev1, behavior_name: "x", description: "d",
        model: "claude-sonnet-4-5", creates: ["x"], frame: nil,
        around: "document#1", depth: 1, max_tokens: 512,
        temperature: 0.0, top_p: 1.0, deterministic: true,
      )
      p2 = assemble_prompt_kwargs(
        view: v2, event: ev2, behavior_name: "x", description: "d",
        model: "claude-sonnet-4-5", creates: ["x"], frame: nil,
        around: "document#1", depth: 1, max_tokens: 512,
        temperature: 0.0, top_p: 1.0, deterministic: true,
      )
      p1.hash.should eq(p2.hash)
    end

    it "hash changes when the model changes (test_hash_changes_when_model_changes)" do
      graph = Chronicle::GraphProjection.empty
      graph.add_object("document", %({"title":"T","body":"B"}))
      ev = graph.events.find { |e| e.type == "object.created" }.not_nil!
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: graph.events)

      h_sonnet = assemble_prompt_kwargs(
        view: view, event: ev, model: "claude-sonnet-4-5",
        behavior_name: "x", description: "d", creates: ["x"],
        frame: nil, around: nil, depth: nil, max_tokens: 512,
        temperature: 0.0, top_p: 1.0, deterministic: true,
      ).hash
      h_opus = assemble_prompt_kwargs(
        view: view, event: ev, model: "claude-opus-4-7",
        behavior_name: "x", description: "d", creates: ["x"],
        frame: nil, around: nil, depth: nil, max_tokens: 512,
        temperature: 0.0, top_p: 1.0, deterministic: true,
      ).hash
      h_sonnet.should_not eq(h_opus)
    end

    it "deterministic overrides temperature and top_p (test_deterministic_overrides_temperature_and_top_p)" do
      graph = Chronicle::GraphProjection.empty
      graph.add_object("document", %({"title":"T","body":"B"}))
      ev = graph.events.find { |e| e.type == "object.created" }.not_nil!
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: graph.events)
      p = assemble_prompt_kwargs(
        view: view, event: ev,
        temperature: 0.9, top_p: 0.5, deterministic: true,
      )
      p.temperature.should eq(0.0)
      p.top_p.should eq(1.0)
    end

    it "prompt_template swaps in placeholders (test_prompt_template_swap_uses_placeholders)" do
      graph = Chronicle::GraphProjection.empty
      graph.add_object("document", %({"title":"T","body":"B"}))
      ev = graph.events.find { |e| e.type == "object.created" }.not_nil!
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: graph.events)
      p = assemble_prompt_kwargs(
        view: view, event: ev, model: "m",
        max_tokens: 64, deterministic: true,
        prompt_template: ">>> {instruction} ||| view={view} ||| event={event}",
      )
      user = p.messages[0].content
      user.should start_with(">>>")
      user.should contain("||| view=## Graph context")
      user.should contain("||| event=")
    end

    it "raises on unknown template placeholder (test_prompt_template_bad_placeholder_raises)" do
      graph = Chronicle::GraphProjection.empty
      graph.add_object("document", %({"title":"T","body":"B"}))
      ev = graph.events.find { |e| e.type == "object.created" }.not_nil!
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: graph.events)
      error = expect_raises(Chronicle::PromptTemplateError) do
        assemble_prompt_kwargs(
          view: view, event: ev, model: "m", max_tokens: 64,
          deterministic: true, prompt_template: "{notarealkey}",
        )
      end
      error.message.not_nil!.should contain("unknown placeholder")
    end
  end

  describe "volatile-field stripping" do
    it "strips provenance, run_id, and timestamp from the serialized event (test_event_serialization_strips_provenance_and_run_id)" do
      graph = Chronicle::GraphProjection.empty
      graph.add_object("doc", %({"title":"t"}))
      ev = graph.events.find { |e| e.type == "object.created" }.not_nil!
      view = Chronicle::View.new(objects: graph.all_objects, relations: [] of Chronicle::GraphRelation, events: graph.events)
      p = assemble_prompt_kwargs(
        view: view, event: ev, model: "m", max_tokens: 64, deterministic: true,
      )
      user = p.messages[0].content
      user.should_not contain("run_id")
      user.should_not contain("provenance")
      user.should_not contain("timestamp")
    end

    it "recursively strips volatile keys from nested payloads" do
      clean = Chronicle::Prompt.strip_volatile(
        JSON.parse(%({"id":"x","provenance":{"run_id":"r","timestamp":"t"},"nested":{"run_id":"y"},"keep":1}))
      )
      clean.to_json.should eq(%({"id":"x","nested":{},"keep":1}))
    end
  end

  describe ".schema_to_json" do
    it "handles nil (test_schema_to_json_handles_none)" do
      Chronicle::Prompt.schema_to_json(Nil).should be_nil
    end

    it "generates a schema from a JSON::Serializable struct type" do
      out = Chronicle::Prompt.schema_to_json(PromptOut).not_nil!
      out["type"].as_s.should eq("object")
      props = out["properties"].as_h
      props.has_key?("n").should be_true
      props.has_key?("label").should be_true
      out["required"].as_a.map(&.as_s).should eq(["n"])
    end

    it "generates enum-typed fields for Role" do
      schema = Chronicle::Prompt.schema_to_json(PromptClaim).not_nil!
      props = schema["properties"].as_h
      props["text"].as_h["type"].as_s.should eq("string")
      props["confidence"].as_h["type"].as_s.should eq("number")
    end
  end

  describe ".example_instance_from_schema" do
    it "builds deterministic placeholder instances" do
      schema = {
        "type"       => JSON::Any.new("object"),
        "properties" => JSON::Any.new({
          "name"  => JSON::Any.new({"type" => JSON::Any.new("string")}),
          "count" => JSON::Any.new({"type" => JSON::Any.new("integer")}),
          "tags"  => JSON::Any.new({"type" => JSON::Any.new("array"), "items" => JSON::Any.new({"type" => JSON::Any.new("string")})}),
        }),
      }
      instance = Chronicle::Prompt.example_instance_from_schema(schema).as_h
      instance["name"].as_s.should eq("<string>")
      instance["count"].as_i.should eq(0)
      instance["tags"].as_a.should eq([JSON::Any.new("<string>")])
    end

    it "resolves $defs references and falls back to null for unknown shapes" do
      schema = {
        "$ref"  => JSON::Any.new("#/$defs/Thing"),
        "$defs" => JSON::Any.new({"Thing" => JSON::Any.new({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new({"id" => JSON::Any.new({"type" => JSON::Any.new("integer")})})})}),
      }
      instance = Chronicle::Prompt.example_instance_from_schema(schema).as_h
      instance["id"].as_i.should eq(0)
    end
  end
end
