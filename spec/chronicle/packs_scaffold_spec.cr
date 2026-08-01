require "../spec_helper"

# Pack scaffolding. Ported from activegraph tests/test_pack_scaffold.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
describe Chronicle::Packs::Scaffold do
  it "normalizes kebab-case to snake for the module name" do
    pack_name, module_name = Chronicle::Packs::Scaffold.normalize_pack_name("my-pack")
    pack_name.should eq("my-pack")
    module_name.should eq("my_pack")
  end

  it "keeps an already-snake name" do
    pack_name, module_name = Chronicle::Packs::Scaffold.normalize_pack_name("simple")
    pack_name.should eq("simple")
    module_name.should eq("simple")
  end

  it "rejects a name starting with a disallowed character" do
    expect_raises(ArgumentError) do
      Chronicle::Packs::Scaffold.normalize_pack_name("-leading-hyphen")
    end
  end

  it "rejects a name starting with a digit" do
    expect_raises(ArgumentError) do
      Chronicle::Packs::Scaffold.normalize_pack_name("9pack")
    end
  end

  it "creates the expected layout" do
    dir = pack_spec_dir("packs_scaffold_spec")
    root = Chronicle::Packs::Scaffold.scaffold_pack(dir, "test-pack")
    root.should eq(File.join(dir, "test-pack"))

    File.file?(File.join(root, "shard.yml")).should be_true
    File.file?(File.join(root, "README.md")).should be_true
    File.file?(File.join(root, "test_pack.cr")).should be_true
    File.file?(File.join(root, "test_pack", "version.cr")).should be_true
    File.file?(File.join(root, "test_pack", "settings.cr")).should be_true
    File.file?(File.join(root, "test_pack", "object_types.cr")).should be_true
    File.file?(File.join(root, "test_pack", "behaviors.cr")).should be_true
    File.file?(File.join(root, "test_pack", "tools.cr")).should be_true
    File.file?(File.join(root, "test_pack", "prompts", "example_prompt.md")).should be_true
    File.file?(File.join(root, "spec", "test_pack_spec.cr")).should be_true
  end

  it "refuses to overwrite an existing pack directory" do
    dir = pack_spec_dir("packs_scaffold_spec")
    Chronicle::Packs::Scaffold.scaffold_pack(dir, "test-pack")
    expect_raises(File::AlreadyExistsError) do
      Chronicle::Packs::Scaffold.scaffold_pack(dir, "test-pack")
    end
  end
end
