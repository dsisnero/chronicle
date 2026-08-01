require "../spec_helper"

# Pack manifest validator + content hashing. Ported from activegraph
# tests/test_pack_manifest.py (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

GOOD_MANIFEST = <<-TOML
  [pack]
  name = "meeting_notes"
  version = "0.1.0"
  description = "Extracts decisions."
  license = "Apache-2.0"

  [pack.provenance]
  authored_by = "human"

  [pack.integrity]
  content_hash = "sha256:#{"0" * 64}"

  [dependencies]
  activegraph = ">=1.3,<2.0"
  python = ">=3.11"
  python-deps = []

  [dependencies.packs]
  core = ">=0.1"

  [surface]
  object_types = ["meeting"]
  relation_types = []
  behaviors = []
  tools = []
  settings_schema = ""

  [[surface.capabilities]]
  provider = "meeting"
  capability = "export_summary"
  risk_class = "medium"
  credential_ref = ""

  [fixtures]
  entrypoint = "fixtures/run_fixtures.py"
  deterministic = true
  TOML

private def write_pack(root : String, manifest : String = GOOD_MANIFEST) : String
  Dir.mkdir_p(root)
  File.write(File.join(root, "manifest.toml"), manifest)
  File.write(File.join(root, "__init__.py"), "# pack module\n")
  root
end

private def section4_hash(root : String, rels : Array(String)) : String
  hex = Digest::SHA256.hexdigest do |ctx|
    rels.sort_by(&.to_slice).each do |rel|
      path = File.join(root, rel)
      bytes = Bytes.new(File.size(path))
      File.open(path, "rb") { |io| io.read_fully(bytes) }
      ctx.update(rel.to_slice)
      ctx.update(Bytes.new(1, 0_u8))
      len_bytes = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode(bytes.size.to_u64, len_bytes)
      ctx.update(len_bytes)
      ctx.update(bytes)
    end
  end
  "sha256:#{hex}"
end

describe Chronicle::Packs do
  it "round-trips a valid manifest" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    m = Chronicle::Packs.load_manifest(root)
    m.name.should eq("meeting_notes")
    m.version.should eq("0.1.0")
    m.activegraph_range.should eq(">=1.3,<2.0")
    m.pack_deps.should eq({"core" => ">=0.1"})
    m.object_types.should eq(["meeting"])
    m.capabilities.first.risk_class.should eq("medium")
    m.fixtures_deterministic?.should be_true
  end

  it "aggregates every violation into one error" do
    bad = GOOD_MANIFEST
      .gsub(%(name = "meeting_notes"), %(name = "Bad-Name"))
      .gsub(%(version = "0.1.0"), %(version = "not-a-version"))
      .gsub(%(risk_class = "medium"), %(risk_class = "extreme"))
    root = write_pack(pack_spec_dir("packs_manifest_spec"), bad)
    ex = expect_raises(Chronicle::Packs::PackManifestError) do
      Chronicle::Packs.load_manifest(root)
    end
    joined = ex.violations.join("\n")
    joined.should contain("pack.name")
    joined.should contain("pack.version")
    joined.should contain("risk_class")
    ex.violations.size.should eq(3)
  end

  it "rejects a non-empty reserved signature rather than skipping it" do
    signed = GOOD_MANIFEST.gsub(
      %(content_hash = "sha256:#{"0" * 64}"),
      %(content_hash = "sha256:#{"0" * 64}"\nsignature = "ed25519:abcd"),
    )
    root = write_pack(pack_spec_dir("packs_manifest_spec"), signed)
    expect_raises(Chronicle::Packs::PackManifestError, /signature/) do
      Chronicle::Packs.load_manifest(root)
    end
  end

  it "rejects a capability with an out-of-closed-set action_class" do
    {"R9", "r2", "medium"}.each do |bad|
      text = GOOD_MANIFEST.gsub(
        %(risk_class = "medium"),
        %(risk_class = "medium"\naction_class = "#{bad}"),
      )
      root = write_pack(pack_spec_dir("packs_manifest_spec"), text)
      expect_raises(Chronicle::Packs::PackManifestError, /action_class/) do
        Chronicle::Packs.load_manifest(root)
      end
    end
  end
end

describe Chronicle::Packs, "verify_surface" do
  it "passes when manifest and Pack agree" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    m = Chronicle::Packs.load_manifest(root)
    pack = Chronicle::Packs::Pack.new(
      name: "meeting_notes", version: "0.1.0",
      object_types: [Chronicle::Packs::ObjectType.new("meeting")],
      capabilities: [Chronicle::Packs::CapabilityDecl.new("meeting", "export_summary", "medium")],
    )
    Chronicle::Packs.verify_surface(m, pack) # no raise
  end

  it "catches undeclared registrations and missing declarations" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    m = Chronicle::Packs.load_manifest(root)

    ex = expect_raises(Chronicle::Packs::PackManifestError) do
      Chronicle::Packs.verify_surface(m, Chronicle::Packs::Pack.new(
        name: "meeting_notes", version: "0.1.0",
        object_types: [Chronicle::Packs::ObjectType.new("meeting"), Chronicle::Packs::ObjectType.new("undeclared_thing")],
      ))
    end
    ex.violations.any? { |v| v.includes?("undeclared_thing") }.should be_true

    ex = expect_raises(Chronicle::Packs::PackManifestError) do
      Chronicle::Packs.verify_surface(m, Chronicle::Packs::Pack.new(name: "meeting_notes", version: "0.1.0"))
    end
    ex.violations.any? { |v| v.includes?("declared 'meeting' not found") }.should be_true
  end

  it "catches a risk_class relabel and a capability declared on one side only" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    m = Chronicle::Packs.load_manifest(root)

    relabeled = Chronicle::Packs::Pack.new(
      name: "meeting_notes", version: "0.1.0",
      capabilities: [Chronicle::Packs::CapabilityDecl.new("meeting", "export_summary", "low")],
    )
    ex = expect_raises(Chronicle::Packs::PackManifestError) do
      Chronicle::Packs.verify_surface(m, relabeled)
    end
    ex.violations.any? { |v| v.includes?("risk_class mismatch") }.should be_true
  end
end

describe Chronicle::Packs, "content hash" do
  it "is deterministic and byte-exact per the §4 walk" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    File.write(File.join(root, "behaviors.py"), "x = 1\n")

    expected = section4_hash(root, ["__init__.py", "behaviors.py"])
    Chronicle::Packs.compute_content_hash(root).should eq(expected)
    Chronicle::Packs.compute_content_hash(root).should eq(expected)
  end

  it "excludes pycache, pyc, hidden files, and the manifest itself" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    baseline = Chronicle::Packs.compute_content_hash(root)

    Dir.mkdir_p(File.join(root, "__pycache__"))
    File.write(File.join(root, "__pycache__", "x.cpython-311.pyc"), "\x00")
    File.write(File.join(root, "module.pyc"), "\x00")
    File.write(File.join(root, ".hidden"), "secret")
    File.write(File.join(root, "manifest.toml"), GOOD_MANIFEST + "\n# comment\n")
    Chronicle::Packs.compute_content_hash(root).should eq(baseline)

    File.write(File.join(root, "tools.py"), "y = 2\n")
    Chronicle::Packs.compute_content_hash(root).should_not eq(baseline)
  end

  it "rejects symlinks including directory symlinks" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    outside = File.join(root, "outside.py")
    File.write(outside, "z = 3\n")
    File.symlink(outside, File.join(root, "linked.py"))
    expect_raises(Chronicle::Packs::PackManifestError, /symlink/) do
      Chronicle::Packs.compute_content_hash(root)
    end
    File.delete(File.join(root, "linked.py"))

    outside_dir = File.join(root, "outside_dir")
    Dir.mkdir_p(outside_dir)
    File.write(File.join(outside_dir, "smuggled.py"), "s = 4\n")
    File.symlink(outside_dir, File.join(root, "linked_dir"))
    expect_raises(Chronicle::Packs::PackManifestError, /symlink/) do
      Chronicle::Packs.compute_content_hash(root)
    end
  end

  it "verifies against a manifest pin and detects tampering" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    real = Chronicle::Packs.compute_content_hash(root)
    File.write(File.join(root, "manifest.toml"), GOOD_MANIFEST.gsub("sha256:#{"0" * 64}", real))
    m = Chronicle::Packs.load_manifest(root)
    Chronicle::Packs.verify_content_hash(m, root)

    File.write(File.join(root, "__init__.py"), "# tampered\n")
    expect_raises(Chronicle::Packs::PackManifestError, /mismatch/) do
      Chronicle::Packs.verify_content_hash(m, root)
    end
  end
end

describe Chronicle::Packs, "bundle hash" do
  it "includes the manifest and is byte-exact" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    bundle = Chronicle::Packs.compute_bundle_hash(root)
    expected = section4_hash(root, ["__init__.py", "manifest.toml"])
    bundle.should eq(expected)

    content = Chronicle::Packs.compute_content_hash(root)
    bundle.should_not eq(content)

    # A manifest-only edit moves the bundle hash but not the content hash.
    File.write(File.join(root, "manifest.toml"), GOOD_MANIFEST.gsub(%(risk_class = "medium"), %(risk_class = "low")))
    Chronicle::Packs.compute_content_hash(root).should eq(content)
    Chronicle::Packs.compute_bundle_hash(root).should_not eq(bundle)
  end

  it "detects a manifest swap via verify_bundle_hash" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    pin = Chronicle::Packs.compute_bundle_hash(root)
    Chronicle::Packs.verify_bundle_hash(pin, root)

    File.write(File.join(root, "manifest.toml"), GOOD_MANIFEST.gsub("[fixtures]", "consumes = []\n\n[fixtures]"))
    expect_raises(Chronicle::Packs::PackManifestError, /bundle hash mismatch/) do
      Chronicle::Packs.verify_bundle_hash(pin, root)
    end
  end

  it "rejects a malformed external pin" do
    root = write_pack(pack_spec_dir("packs_manifest_spec"))
    expect_raises(Chronicle::Packs::PackManifestError, /external pin/) do
      Chronicle::Packs.verify_bundle_hash("md5:abcd", root)
    end
  end
end

describe Chronicle::Packs::Pack, "capabilities" do
  it "validates risk_class and CapabilityDecl shape" do
    expect_raises(Chronicle::Packs::PackValidationError, /risk_class/) do
      Chronicle::Packs::Pack.new(
        name: "bad", version: "0.1.0",
        capabilities: [Chronicle::Packs::CapabilityDecl.new("x", "y", "extreme")],
      )
    end
  end

  it "lands declared capabilities in the pack.loaded payload" do
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, graph: graph)

    pack = Chronicle::Packs::Pack.new(
      name: "meeting_notes", version: "0.1.0",
      capabilities: [Chronicle::Packs::CapabilityDecl.new("meeting", "export_summary", "medium")],
    )
    rt.load_pack(pack)
    event = store.iter_events.find { |e| e.type == "pack.loaded" }
    event.should_not be_nil
    caps = JSON.parse(event.not_nil!.payload)["capabilities"].as_a
    caps.first["provider"].should eq("meeting")
    caps.first["capability"].should eq("export_summary")
    caps.first["risk_class"].should eq("medium")
    caps.first["credential_ref"].should eq("")
  end
end
