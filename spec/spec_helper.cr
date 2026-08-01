require "spec"
require "../src/chronicle"
require "./support/pack_spec_model"

# Scratch dir for pack prompt / manifest / scaffold specs. Lives under
# `temp/` (gitignored, cleared by `make clean`). Wipes the whole dir so
# stale packs from earlier examples can't leak into later ones. Uses `rm -rf`
# because FileUtils.rm_rf trips over the macOS AppleDouble `._` residue that
# the git checkout leaves behind on this volume.
def pack_spec_dir(name : String) : String
  path = File.join("temp", name)
  if File.exists?(path)
    Process.run("rm", ["-rf", path])
  end
  Dir.mkdir_p(path)
  path
end
