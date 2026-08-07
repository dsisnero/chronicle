require "../spec_helper"

# `Runtime#pack_settings(pack_name)` — Form 3 cross-pack settings lookup
# (CONTRACT v0.9 #7). Ported from activegraph.runtime.runtime.Runtime#pack_settings:
# returns the canonical settings hash for any loaded pack by name, or nil if the
# pack isn't loaded. (Upstream's `_pack_settings_for_behavior` is a private
# helper; Chronicle's dispatch already inlines that lookup, so only the public
# form is ported.)

module PackSettingsProbe
  include Chronicle::Packs::DSL

  struct ProbeSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    property threshold : Float64 = 0.5
  end

  @[Behavior(name: "probe", on: ["goal.created"])]
  def probe(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # no-op
  end

  pack(name: "settingsprobe", version: "0.1.0", settings_schema: ProbeSettings)
end

private def pack_settings_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

describe Chronicle::Runtime do
  it "pack_settings returns nil for an unknown pack" do
    rt = pack_settings_runtime
    rt.pack_settings("never_loaded").should be_nil
  end

  it "pack_settings returns the canonical settings for a loaded pack" do
    rt = pack_settings_runtime
    rt.load_pack(PackSettingsProbe::PACK, settings: {"threshold" => JSON::Any.new(0.9_f64)})

    settings = rt.pack_settings("settingsprobe")
    settings.should_not be_nil
    settings.not_nil!["threshold"].as_f.should eq(0.9)
  end

  it "pack_settings returns nil after the pack is disabled" do
    rt = pack_settings_runtime
    rt.load_pack(PackSettingsProbe::PACK)
    rt.disable_pack("settingsprobe")
    rt.pack_settings("settingsprobe").should be_nil
  end
end
