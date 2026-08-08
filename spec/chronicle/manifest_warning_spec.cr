require "../spec_helper"

# Manifest warning tier (CONTRACT v1.6 #1): when a manifest.toml is supplied to
# load_pack and verify_surface finds violations, the pack still loads but the
# loader records a structured warning — never an error before 2.0. Absent
# manifest: silent. Ported from activegraph.packs.loader._warn_on_manifest_violations.

require "file"
require "file_utils"

module ManifestWarningPack
  include Chronicle::Packs::DSL

  @[Behavior(name: "probe", on: ["goal.created"])]
  def probe(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    # no-op
  end

  pack(name: "manifestwarning", version: "0.1.0")
end

private def manifest_warning_runtime : Chronicle::Runtime(PackModel)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
  la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
  Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)
end

private def manifest_warning_path(tag : String) : String
  dir = File.join(Dir.tempdir, "chronicle_manifest_warning_#{tag}_#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  dir
end

# A manifest whose surface disagrees with the loaded pack (name differs).
private def write_mismatched_manifest(root : String) : String
  path = File.join(root, "manifest.toml")
  File.write(path, <<-TOML)
    [pack]
    name = "different_name"
    version = "9.9.9"
    activegraph = ">=1.3,<2.0"

    [surface]
    object_types = []
    relation_types = []
    behaviors = []
    tools = []
    settings_schema = ""
  TOML
  path
end

describe Chronicle::Runtime do
  it "load_pack records a warning but still loads when the manifest surface mismatches" do
    rt = manifest_warning_runtime
    root = manifest_warning_path("mismatch")
    manifest = write_mismatched_manifest(root)

    rt.load_pack(ManifestWarningPack::PACK, manifest_path: manifest).should be_true
    rt.loaded_packs.should eq(["manifestwarning"])
    rt.pack_warnings.any? { |w| w.includes?("manifest") }.should be_true
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end

  it "load_pack is silent about the manifest when it verifies clean" do
    rt = manifest_warning_runtime
    root = manifest_warning_path("clean")
    path = File.join(root, "manifest.toml")
    File.write(path, <<-TOML)
      [pack]
      name = "manifestwarning"
      version = "0.1.0"
      description = "warns"
      license = "Apache-2.0"

      [pack.provenance]
      authored_by = "human"

      [pack.integrity]
      content_hash = "sha256:#{"0" * 64}"

      [dependencies]
      activegraph = ">=1.3,<2.0"
      python = ">=3.11"
      python-deps = []

      [surface]
      object_types = []
      relation_types = []
      behaviors = ["probe"]
      tools = []
      settings_schema = ""

      [fixtures]
      entrypoint = "fixtures/run_fixtures.py"
      deterministic = true
    TOML

    rt.load_pack(ManifestWarningPack::PACK, manifest_path: path).should be_true
    rt.pack_warnings.should be_empty
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end

  it "load_pack is silent when no manifest path is supplied" do
    rt = manifest_warning_runtime
    rt.load_pack(ManifestWarningPack::PACK).should be_true
    rt.pack_warnings.should be_empty
  end
end
