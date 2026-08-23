require "../spec_helper"
require "./packs_dsl_spec"

# Entry-point-style discovery. Ported from activegraph's `discover()` /
# `load_by_name()` / `clear_discovery_cache()` (revision 148e12c2969f18fa12a1a3c2e75f3affd9aa0616).
describe Chronicle::Packs do
  before_each do
    Chronicle::Packs::Registry.clear
  end

  it "enumerates registered packs via discover()" do
    Chronicle::Packs::Registry.register(Chronicle::TestPacks::DemoSettingsPack::PACK)
    Chronicle::Packs::Registry.register(Chronicle::TestPacks::PingPackA::PACK)

    discovered = Chronicle::Packs.discover
    discovered.map(&.name).should contain("demo")
    discovered.map(&.name).should contain("a")
    demo = discovered.find { |d| d.name == "demo" }
    demo.not_nil!.version.should eq("0.1.0")
    demo.not_nil!.entry_point.should eq("demo = demo")
  end

  it "caches discovery results until clear_discovery_cache is called" do
    Chronicle::Packs::Registry.register(Chronicle::TestPacks::DemoSettingsPack::PACK)
    Chronicle::Packs::Registry.register(Chronicle::TestPacks::PingPackA::PACK)
    first = Chronicle::Packs.discover
    # Repeated calls return the cached array (no re-scan).
    Chronicle::Packs.discover.should be(first)

    Chronicle::Packs.clear_discovery_cache
    Chronicle::Packs.discover.should_not be(first)
    Chronicle::Packs.discover.map(&.name).sort.should eq(["a", "demo"])
  end

  it "resolves load_by_name to the Pack object" do
    Chronicle::Packs::Registry.register(Chronicle::TestPacks::PingPackA::PACK)
    pack = Chronicle::Packs.load_by_name("a")
    pack.name.should eq("a")
    pack.version.should eq("0.1.0")
  end

  it "raises PackNotFoundError naming the installed packs" do
    Chronicle::Packs::Registry.register(Chronicle::TestPacks::PingPackA::PACK)
    ex = expect_raises(Chronicle::Packs::PackNotFoundError) do
      Chronicle::Packs.load_by_name("nope")
    end
    ex.pack_name.should eq("nope")
    ex.installed.should contain("a")
  end
end
