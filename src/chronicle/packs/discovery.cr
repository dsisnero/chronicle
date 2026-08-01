module Chronicle
  module Packs
    # A pack discovered via the registry but not yet loaded. What `discover()`
    # yields per registered pack: name/version, the entry-point string it came
    # from, and the Pack object itself.
    struct DiscoveredPack
      getter name : String
      getter version : String
      getter entry_point : String
      getter pack : Pack

      def initialize(@name : String, @version : String, @entry_point : String, @pack : Pack)
      end
    end

    # Crystal-native analogue of activegraph's Python entry-point discovery.
    # Packs register themselves when their module is required (the DSL's
    # `pack(...)` with `register: true`); `discover()` enumerates them and is
    # cached per process until `clear_discovery_cache()` is called.
    class Registry
      @@packs = [] of Pack
      @@cache : Array(DiscoveredPack)?

      def self.register(pack : Pack) : Nil
        unless @@packs.any? { |pack_| pack_.name == pack.name && pack_.version == pack.version }
          @@packs << pack
        end
        @@cache = nil
      end

      def self.discover : Array(DiscoveredPack)
        @@cache ||= @@packs.map do |pack_|
          DiscoveredPack.new(
            name: pack_.name,
            version: pack_.version,
            entry_point: "#{pack_.name} = #{pack_.name}",
            pack: pack_,
          )
        end
      end

      def self.clear_discovery_cache : Nil
        @@cache = nil
      end

      def self.clear : Nil
        @@packs.clear
        @@cache = nil
      end

      def self.load_by_name(name : String) : Pack
        installed = discover.map(&.name)
        entry = discover.find { |discovered| discovered.name == name }
        raise PackNotFoundError.new(name, installed: installed) if entry.nil?
        entry.pack
      end
    end

    # Enumerate registered packs. Cached per process; call
    # `clear_discovery_cache` to force a re-scan.
    def self.discover : Array(DiscoveredPack)
      Registry.discover
    end

    def self.clear_discovery_cache : Nil
      Registry.clear_discovery_cache
    end

    # Find a discovered pack by name. Raises PackNotFoundError when the name
    # doesn't resolve.
    def self.load_by_name(name : String) : Pack
      Registry.load_by_name(name)
    end
  end
end
