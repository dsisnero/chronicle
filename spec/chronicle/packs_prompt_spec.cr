require "../spec_helper"

# Prompt loading specs. Ported from activegraph tests/test_packs.py
# (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).
describe Chronicle::Packs::PackPrompt do
  it "computes a content hash from a body" do
    p = Chronicle::Packs::PackPrompt.from_body(name: "x", version: "1.0.0", body: "hello")
    p.content_hash.should start_with("sha256:")
    p.body.should eq("hello")
  end

  it "produces a stable content hash for the same body" do
    a = Chronicle::Packs::PackPrompt.from_body(name: "x", version: "1.0.0", body: "Body content.")
    b = Chronicle::Packs::PackPrompt.from_body(name: "x", version: "1.0.0", body: "Body content.")
    a.content_hash.should eq(b.content_hash)
  end

  it "changes the hash when the body changes" do
    a = Chronicle::Packs::PackPrompt.from_body(name: "x", version: "1.0.0", body: "Original body.")
    b = Chronicle::Packs::PackPrompt.from_body(name: "x", version: "1.0.0", body: "Different body.")
    a.content_hash.should_not eq(b.content_hash)
  end
end

describe Chronicle::Packs do
  it "loads prompts from a directory with TOML frontmatter" do
    dir = pack_spec_dir("packs_prompt_spec")
    prompts_dir = File.join(dir, "prompts")
    Dir.mkdir_p(prompts_dir)
    File.write(File.join(prompts_dir, "first.md"), <<-MD)
      ---
      version = "1.2.3"
      ---
      Body of the first prompt.
      MD
    File.write(File.join(prompts_dir, "second.md"), <<-MD)
      ---
      version = "0.1.0"
      name = "renamed_second"
      ---
      Body of the second prompt.
      MD

    prompts = Chronicle::Packs.load_prompts_from_dir(prompts_dir)
    by_name = prompts.to_h { |p| {p.name, p} }
    by_name.has_key?("first").should be_true
    by_name.has_key?("renamed_second").should be_true
    by_name["first"].version.should eq("1.2.3")
    by_name["renamed_second"].version.should eq("0.1.0")
    by_name["first"].body.should eq("Body of the first prompt.")
  end

  it "loads prompts sorted by name" do
    dir = pack_spec_dir("packs_prompt_spec")
    prompts_dir = File.join(dir, "prompts_sorted")
    Dir.mkdir_p(prompts_dir)
    File.write(File.join(prompts_dir, "b.md"), "---\nversion = \"1.0.0\"\n---\nB body.")
    File.write(File.join(prompts_dir, "a.md"), "---\nversion = \"1.0.0\"\n---\nA body.")

    prompts = Chronicle::Packs.load_prompts_from_dir(prompts_dir)
    prompts.map(&.name).should eq(["a", "b"])
  end

  it "rejects missing frontmatter" do
    dir = pack_spec_dir("packs_prompt_spec")
    prompts_dir = File.join(dir, "prompts_broken")
    Dir.mkdir_p(prompts_dir)
    File.write(File.join(prompts_dir, "broken.md"), "No frontmatter here.")
    expect_raises(Chronicle::Packs::PackPromptLoadError, /frontmatter/) do
      Chronicle::Packs.load_prompts_from_dir(prompts_dir)
    end
  end

  it "rejects frontmatter missing the required version key" do
    dir = pack_spec_dir("packs_prompt_spec")
    prompts_dir = File.join(dir, "prompts_noversion")
    Dir.mkdir_p(prompts_dir)
    File.write(File.join(prompts_dir, "p.md"), "---\nname = \"x\"\n---\nBody.")
    expect_raises(Chronicle::Packs::PackPromptLoadError, /version/) do
      Chronicle::Packs.load_prompts_from_dir(prompts_dir)
    end
  end

  it "rejects malformed TOML frontmatter" do
    dir = pack_spec_dir("packs_prompt_spec")
    prompts_dir = File.join(dir, "prompts_badtoml")
    Dir.mkdir_p(prompts_dir)
    File.write(File.join(prompts_dir, "p.md"), "---\nthis is not = valid = toml\n---\nBody.")
    expect_raises(Chronicle::Packs::PackPromptLoadError, /TOML/) do
      Chronicle::Packs.load_prompts_from_dir(prompts_dir)
    end
  end

  it "rejects a missing prompts directory" do
    dir = pack_spec_dir("packs_prompt_spec")
    expect_raises(Chronicle::Packs::PackPromptLoadError, /does not exist/) do
      Chronicle::Packs.load_prompts_from_dir(File.join(dir, "nope_missing_dir"))
    end
  end

  it "rejects duplicate prompt names" do
    dir = pack_spec_dir("packs_prompt_spec")
    prompts_dir = File.join(dir, "prompts_dup")
    Dir.mkdir_p(prompts_dir)
    File.write(File.join(prompts_dir, "a.md"), "---\nversion = \"1.0.0\"\n---\nA body.")
    File.write(File.join(prompts_dir, "b.md"), "---\nversion = \"1.0.0\"\nname = \"a\"\n---\nB body.")
    expect_raises(Chronicle::Packs::PackPromptLoadError, /duplicate prompt name/) do
      Chronicle::Packs.load_prompts_from_dir(prompts_dir)
    end
  end
end
