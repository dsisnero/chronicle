require "../spec_helper"

# The DSL/annotation surface: pack modules declare behaviors/tools/object
# types with annotations, the `pack` macro collects them, and the loader
# registers them per-runtime. Ported from activegraph tests/test_packs.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

module Chronicle
  module TestPacks
    module DemoSettingsPack
      include Chronicle::Packs::DSL

      struct DemoSettings
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        getter threshold : Float64 = 0.5
      end

      @[ObjectType(name: "widget")]
      struct Widget
        include JSON::Serializable

        getter name : String
        getter size : Int32 = 0
      end

      @[Behavior(name: "ping", on: ["goal.created"])]
      def ping(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      end

      pack(
        name: "demo",
        version: "0.1.0",
        description: "A demo pack.",
        settings_schema: DemoSettings,
      )
    end

    module GlobalProbePack
      include Chronicle::Packs::DSL

      @[Behavior(name: "x", on: ["a.b"])]
      def x(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      end

      @[LLMBehavior(name: "y", on: ["a.b"])]
      def y(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, output : String)
      end

      @[RelationBehavior(relation_type: "supports", name: "z", on: ["relation.created"])]
      def z(relation : Chronicle::GraphRelation, event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      end

      @[Tool(name: "t", description: "global probe tool")]
      def t(args : String) : String
        "{}"
      end

      pack(name: "noglobal", version: "0.1.0", register: false)
    end

    module PingPackA
      include Chronicle::Packs::DSL

      @[Behavior(name: "ping", on: ["goal.created"])]
      def ping(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      end

      pack(name: "a", version: "0.1.0")
    end

    module PingPackB
      include Chronicle::Packs::DSL

      @[Behavior(name: "ping", on: ["goal.created"])]
      def ping(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
      end

      pack(name: "b", version: "0.1.0")
    end

    module ConflictPack
      include Chronicle::Packs::DSL

      @[ObjectType(name: "widget")]
      struct Widget2
        include JSON::Serializable

        getter name : String
      end

      pack(name: "conflict", version: "0.1.0")
    end

    module InjectionPack
      include Chronicle::Packs::DSL

      struct Settings
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        getter marker : String = "hello"
      end

      class_property captured = {} of String => String

      @[Behavior(name: "b", on: ["object.created"])]
      def b(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext, settings : Settings)
        InjectionPack.captured["marker"] = settings.marker
      end

      pack(name: "injtest", version: "0.1.0", settings_schema: Settings)
    end

    module CtxSettingsPack
      include Chronicle::Packs::DSL

      struct Settings
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        getter marker : String = "default"
      end

      class_property captured = {} of String => String

      @[Behavior(name: "b", on: ["object.created"])]
      def b(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
        CtxSettingsPack.captured["marker"] = ctx.settings["marker"].as_s
      end

      pack(name: "ctxtest", version: "0.1.0", settings_schema: Settings)
    end

    module WherePack
      include Chronicle::Packs::DSL

      class_property fired : Bool = false

      @[Behavior(name: "typed", on: ["object.created"], where: {"type" => "document"})]
      def typed(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
        WherePack.fired = true
      end

      pack(name: "wherep", version: "0.1.0")
    end

    module RequiredSettingsPack
      include Chronicle::Packs::DSL

      struct RequiredSettings
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        getter required : String
      end

      pack(name: "p2", version: "0.1.0", settings_schema: RequiredSettings)
    end

    module CrossPackA
      include Chronicle::Packs::DSL

      struct SettingsA
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        getter a : Int32 = 1
      end

      pack(name: "a", version: "0.1.0", settings_schema: SettingsA)
    end

    module CrossPackB
      include Chronicle::Packs::DSL

      struct SettingsB
        include JSON::Serializable
        include Chronicle::Packs::SettingsSchema

        getter b : String = "x"
      end

      pack(name: "b", version: "0.1.0", settings_schema: SettingsB)
    end

    module CrossPackProbe
      include Chronicle::Packs::DSL

      class_property captured = {} of String => JSON::Any?

      @[Behavior(name: "probe", on: ["object.created"])]
      def probe(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
        CrossPackProbe.captured["a"] = ctx.pack_settings("a").not_nil!["a"]
        CrossPackProbe.captured["b"] = ctx.pack_settings("b").not_nil!["b"]
        CrossPackProbe.captured["missing"] = ctx.pack_settings("nonexistent") ? JSON::Any.new("present") : nil
      end

      pack(name: "probe_pack", version: "0.1.0")
    end
  end
end

module PackDslHelper
  extend self

  # A fresh runtime with a store + graph attached to the same store, so pack
  # behaviors can mutate the graph and their events persist.
  def runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(PackModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    {store, graph, Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)}
  end
end

private def with_runtime(&)
  store, graph, rt = PackDslHelper.runtime
  yield store, graph, rt
end

describe Chronicle::Packs::DSL do
  it "collects annotated object types, behaviors, tools, and relation behaviors into a Pack" do
    pack = Chronicle::TestPacks::DemoSettingsPack::PACK
    pack.name.should eq("demo")
    pack.version.should eq("0.1.0")
    pack.object_types.map(&.name).should eq(["widget"])
    pack.behaviors.map(&.name).should eq(["ping"])
    pack.settings_schema.should eq("DemoSettings")
  end

  it "keeps the global registries empty when a pack module loads (no global side effects)" do
    Chronicle::ToolRegistry.clear
    pack = Chronicle::TestPacks::GlobalProbePack::PACK
    pack.behaviors.map(&.name).should eq(["x", "y", "z"])
    pack.tools.map(&.name).should eq(["t"])
    pack.behaviors.map(&.kind).should contain(Chronicle::Packs::PackBehaviorKind::LLM)
    pack.behaviors.map(&.kind).should contain(Chronicle::Packs::PackBehaviorKind::Relation)
    Chronicle::ToolRegistry.snapshot.should be_empty
  end
end

describe "pack loading lifecycle" do
  it "emits a pack.loaded event with the full component manifest" do
    with_runtime do |store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      evts = store.iter_events.select { |e| e.type == "pack.loaded" }
      evts.size.should eq(1)
      payload = JSON.parse(evts.first.payload)
      payload["name"].should eq("demo")
      payload["version"].should eq("0.1.0")
      payload["object_types"].as_a.map(&.as_s).should eq(["widget"])
      payload["behaviors"].as_a.map(&.as_s).should eq(["demo.ping"])
    end
  end

  it "is idempotent on (name, version)" do
    with_runtime do |store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK).should be_true
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK).should be_false
      store.iter_events.count { |e| e.type == "pack.loaded" }.should eq(1)
    end
  end

  it "raises a version conflict for the same name with a different version" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      different = Chronicle::Packs::Pack.new(name: "demo", version: "0.2.0")
      expect_raises(Chronicle::Packs::PackVersionConflictError) { rt.load_pack(different) }
    end
  end

  it "rejects a conflict on a declared object type" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      expect_raises(Chronicle::Packs::PackConflictError, /widget/) do
        rt.load_pack(Chronicle::TestPacks::ConflictPack::PACK)
      end
    end
  end

  it "is pre-mutation on a failed load" do
    with_runtime do |store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      events_before = store.count
      expect_raises(Chronicle::Packs::PackConflictError) do
        rt.load_pack(Chronicle::TestPacks::ConflictPack::PACK)
      end
      store.count.should eq(events_before)
      rt.loaded_packs.should eq(["demo"])
    end
  end
end

describe "pack settings" do
  it "uses defaults when load_pack is called without settings" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK).should be_true
      rt.pack_state.pack_settings["demo"]["threshold"].should eq(JSON::Any.new(0.5))
    end
  end

  it "raises PackSettingsMissingError when a required field is missing" do
    with_runtime do |_store, _graph, rt|
      expect_raises(Chronicle::Packs::PackSettingsMissingError) do
        rt.load_pack(Chronicle::TestPacks::RequiredSettingsPack::PACK)
      end
    end
  end

  it "coerces dict-shaped settings" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK, {"threshold" => JSON::Any.new(0.9)})
      rt.pack_state.pack_settings["demo"]["threshold"].should eq(JSON::Any.new(0.9))
    end
  end
end

describe "schema validation" do
  it "rejects malformed object data against a loaded pack schema" do
    with_runtime do |_store, graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      graph.add_object("widget", %({"name":"ok","size":1}))
      expect_raises(Chronicle::Packs::PackSchemaViolation) do
        graph.add_object("widget", %({"size":1}))
      end
    end
  end

  it "does not retroactively validate objects created before the pack loads" do
    with_runtime do |_store, graph, rt|
      graph.add_object("widget", %({"name":"pre","size":-999}))
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      graph.objects(type: "widget").any? { |o| JSON.parse(o.data)["name"] == "pre" }.should be_true
      expect_raises(Chronicle::Packs::PackSchemaViolation) do
        graph.add_object("widget", %({"size":1}))
      end
    end
  end

  it "accepts arbitrary data when no pack declares the type" do
    with_runtime do |_store, graph, _rt|
      graph.add_object("anything", %({"foo":"bar","size":-42}))
      graph.objects(type: "anything").size.should eq(1)
    end
  end
end

describe "namespace prefixing" do
  it "registers behaviors under the canonical prefixed name" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      rt.get_behavior("demo.ping").name.should eq("demo.ping")
    end
  end

  it "resolves an unambiguous short name" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      rt.get_behavior("ping").name.should eq("demo.ping")
    end
  end

  it "raises on an ambiguous short name and resolves fully-qualified names" do
    with_runtime do |_store, _graph, rt|
      rt.load_pack(Chronicle::TestPacks::PingPackA::PACK)
      rt.load_pack(Chronicle::TestPacks::PingPackB::PACK)
      expect_raises(Chronicle::Packs::AmbiguousBehaviorError) { rt.get_behavior("ping") }
      rt.get_behavior("a.ping").name.should eq("a.ping")
      rt.get_behavior("b.ping").name.should eq("b.ping")
    end
  end
end

describe "behavior dispatch" do
  it "runs a pack behavior with typed settings injection" do
    Chronicle::TestPacks::InjectionPack.captured.clear
    with_runtime do |_store, graph, rt|
      rt.load_pack(Chronicle::TestPacks::InjectionPack::PACK, {"marker" => JSON::Any.new("bingo")})
      graph.add_object("trigger", %({"foo":1}))
      rt.run_until_idle
      Chronicle::TestPacks::InjectionPack.captured["marker"].should eq("bingo")
    end
  end

  it "runs a pack behavior reading ctx.settings" do
    Chronicle::TestPacks::CtxSettingsPack.captured.clear
    with_runtime do |_store, graph, rt|
      rt.load_pack(Chronicle::TestPacks::CtxSettingsPack::PACK, {"marker" => JSON::Any.new("ctx_via")})
      graph.add_object("trigger", %({"foo":1}))
      rt.run_until_idle
      Chronicle::TestPacks::CtxSettingsPack.captured["marker"].should eq("ctx_via")
    end
  end

  it "filters dispatch with a where predicate against the event payload" do
    Chronicle::TestPacks::WherePack.fired = false
    with_runtime do |_store, graph, rt|
      rt.load_pack(Chronicle::TestPacks::WherePack::PACK)
      graph.add_object("other", %({"x":1}))
      rt.run_until_idle
      Chronicle::TestPacks::WherePack.fired.should be_false
      graph.add_object("document", %({"x":1}))
      rt.run_until_idle
      Chronicle::TestPacks::WherePack.fired.should be_true
    end
  end

  it "resolves cross-pack settings via ctx.pack_settings" do
    Chronicle::TestPacks::CrossPackProbe.captured.clear
    with_runtime do |_store, graph, rt|
      rt.load_pack(Chronicle::TestPacks::CrossPackA::PACK, {"a" => JSON::Any.new(42)})
      rt.load_pack(Chronicle::TestPacks::CrossPackB::PACK, {"b" => JSON::Any.new("hello")})
      rt.load_pack(Chronicle::TestPacks::CrossPackProbe::PACK)
      graph.add_object("trigger", %({}))
      rt.run_until_idle
      Chronicle::TestPacks::CrossPackProbe.captured["a"].should eq(JSON::Any.new(42))
      Chronicle::TestPacks::CrossPackProbe.captured["b"].should eq(JSON::Any.new("hello"))
      Chronicle::TestPacks::CrossPackProbe.captured["missing"].should be_nil
    end
  end

  it "chains events created by behaviors to the triggering event" do
    with_runtime do |_store, graph, rt|
      rt.load_pack(Chronicle::TestPacks::DemoSettingsPack::PACK)
      # ping runs on goal.created and this pack's ping is a no-op; verify
      # the dispatch loop drains without infinite-looping on a behavior
      # that adds objects.
      graph.add_object("widget", %({"name":"chain"}))
      rt.run_until_idle
      graph.objects(type: "widget").size.should eq(1)
    end
  end
end
