require "../spec_helper"

# Fork-local settings override: `load_pack` applies recorded
# `pack.settings_overridden` events for the pack onto its settings, so a
# `fork --set` override carries into the fork without touching the parent's
# log (the override lives only in the fork's tail). Ported from
# activegraph.packs.loader._apply_recorded_settings_overrides +
# _merge_settings_override.

module SettingsOverridePack
  include Chronicle::Packs::DSL

  struct SettingsOverrideSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    property n : Int32 = 1
    property enabled : Bool = true
  end

  @[Behavior(name: "probe", on: ["goal.created"])]
  def probe(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # no-op
  end

  pack(name: "settingsoverride", version: "0.1.0", settings_schema: SettingsOverrideSettings)
end

private def settings_override_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

# Record a fork-local pack.settings_overridden event (the CLI `fork --set`
# surface) into the runtime's store.
private def record_override(rt : Chronicle::Runtime(PackModel), overrides : Hash(String, JSON::Any)) : Nil
  rt.store.append(Chronicle::Event.new(
    schema_version: 1_u16,
    sequence: rt.store.count.to_u64 + 1,
    id: "settings_overridden_#{rt.store.count.to_u64 + 1}",
    type: "pack.settings_overridden",
    actor: "runtime",
    caused_by: nil,
    timestamp: Time.utc,
    payload: JSON.build do |json|
      json.object do
        json.field "pack", "settingsoverride"
        json.field "overrides" do
          json.object do
            overrides.each do |key, value|
              json.field key do
                json.raw(value.to_json)
              end
            end
          end
        end
        json.field "assignments", [] of String
      end
    end,
  ))
end

describe Chronicle::Runtime do
  it "load_pack applies a recorded pack.settings_overridden override" do
    rt = settings_override_runtime
    record_override(rt, {"n" => JSON::Any.new(42_i64), "enabled" => JSON::Any.new(false)})

    rt.load_pack(SettingsOverridePack::PACK)
    settings = rt.pack_settings("settingsoverride").not_nil!
    settings["n"].as_i.should eq(42)
    settings["enabled"].as_bool.should be_false
  end

  it "load_pack keeps defaults when no override is recorded" do
    rt = settings_override_runtime
    rt.load_pack(SettingsOverridePack::PACK)
    settings = rt.pack_settings("settingsoverride").not_nil!
    settings["n"].as_i.should eq(1)
    settings["enabled"].as_bool.should be_true
  end

  it "a later override takes precedence over the schema default" do
    rt = settings_override_runtime
    record_override(rt, {"n" => JSON::Any.new(7_i64)})
    rt.load_pack(SettingsOverridePack::PACK)
    settings = rt.pack_settings("settingsoverride").not_nil!
    settings["n"].as_i.should eq(7)
  end
end
