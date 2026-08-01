require "digest/sha256"
require "toml"

module Chronicle
  module Packs
    # The manifest name regex (CONTRACT v1.4): lowercase, starts with a
    # letter, 2..64 chars (note: stricter than the Pack name regex).
    MANIFEST_NAME_RE = /^[a-z][a-z0-9_]{1,63}$/

    # PEP 440 core grammar (syntactic check only).
    VERSION_RE = /^v?\d+(\.\d+)*((a|b|rc)\d+)?(\.post\d+)?(\.dev\d+)?(\+[a-z0-9]+(\.[a-z0-9]+)*)?$/

    # PEP 440 specifier set grammar.
    SPECIFIER_RE = /^\s*(~=|==|!=|<=|>=|<|>|===)\s*[\w.*+!-]+\s*(,\s*(~=|==|!=|<=|>=|<|>|===)\s*[\w.*+!-]+\s*)*$/

    AUTHORED_BY = Set{"human", "agent"}
    HASH_PREFIX = "sha256:"
    HEX64_RE    = /^[0-9a-f]{64}$/

    # A parsed, schema-valid `manifest.toml`. Field names mirror the spec's
    # tables; `raw` preserves the full parsed TOML for consumers that need
    # keys this struct doesn't surface yet.
    struct PackManifest
      getter name : String
      getter version : String
      getter description : String
      getter license : String
      getter authored_by : String
      getter content_hash : String
      getter activegraph_range : String
      getter python_range : String
      getter python_deps : Array(String)
      getter pack_deps : Hash(String, String)
      getter optional_pack_deps : Hash(String, String)
      getter object_types : Array(String)
      getter relation_types : Array(String)
      getter behaviors : Array(String)
      getter tools : Array(String)
      getter settings_schema : String
      getter capabilities : Array(CapabilityDecl)
      getter consumes : Array(String)
      getter fixtures_entrypoint : String
      getter? fixtures_deterministic : Bool
      getter raw : Hash(String, TOML::Any)

      def initialize(
        @name : String,
        @version : String,
        @description : String,
        @license : String,
        @authored_by : String,
        @content_hash : String,
        @activegraph_range : String,
        @python_range : String,
        @python_deps : Array(String),
        @pack_deps : Hash(String, String),
        @optional_pack_deps : Hash(String, String),
        @object_types : Array(String),
        @relation_types : Array(String),
        @behaviors : Array(String),
        @tools : Array(String),
        @settings_schema : String,
        @capabilities : Array(CapabilityDecl),
        @consumes : Array(String),
        @fixtures_entrypoint : String,
        @fixtures_deterministic : Bool,
        @raw : Hash(String, TOML::Any),
      )
      end
    end

    # Parse and schema-validate a `manifest.toml`. `path` is the manifest file
    # or the pack root containing it. Raises PackManifestError carrying every
    # violation; returns the parsed PackManifest when clean.
    # ameba:disable Metrics/CyclomaticComplexity
    def self.load_manifest(path : String) : PackManifest
      p = path
      p = File.join(p, "manifest.toml") if File.directory?(p)
      violations = [] of String

      text = begin
        File.read(p, encoding: "utf-8")
      rescue ex : IO::Error | File::Error
        raise PackManifestError.new(p, ["cannot read manifest: #{ex.message}"])
      end
      data = begin
        TOML.parse(text)
      rescue ex : TOML::ParseException | ArgumentError
        raise PackManifestError.new(p, ["not valid UTF-8 TOML: #{ex.message}"])
      end

      pack_table = table(data, "pack", violations)
      provenance = table_like(pack_table, "provenance", "[pack.provenance]", violations)
      integrity = table_like(pack_table, "integrity", "[pack.integrity]", violations)
      dependencies = table(data, "dependencies", violations)
      surface = table(data, "surface", violations)
      fixtures = table(data, "fixtures", violations)

      name = toml_str(pack_table["name"]?)
      unless name.matches?(MANIFEST_NAME_RE)
        violations << "pack.name #{name.inspect} must match ^[a-z][a-z0-9_]{1,63}$"
      end
      version = toml_str(pack_table["version"]?)
      unless version.matches?(VERSION_RE)
        violations << "pack.version #{version.inspect} is not PEP 440"
      end
      description = toml_str(pack_table["description"]?)
      violations << "pack.description must be nonempty" if description.empty?
      license_ = toml_str(pack_table["license"]?)

      authored_by = toml_str(provenance["authored_by"]?)
      unless AUTHORED_BY.includes?(authored_by)
        violations << "pack.provenance.authored_by #{authored_by.inspect} must be 'human' or 'agent'"
      end

      content_hash = toml_str(integrity["content_hash"]?)
      if !content_hash.starts_with?(HASH_PREFIX) || !content_hash[HASH_PREFIX.size..].matches?(HEX64_RE)
        violations << "pack.integrity.content_hash #{content_hash.inspect} must be 'sha256:' + 64 lowercase hex chars"
      end
      signature = toml_str(integrity["signature"]?)
      if !signature.empty?
        violations << "pack.integrity.signature is reserved; no algorithm is implemented yet, and a non-empty value must be rejected rather than skipped"
      end

      ag_range = toml_str(dependencies["activegraph"]?)
      if ag_range.empty? || !ag_range.matches?(SPECIFIER_RE)
        violations << "dependencies.activegraph #{ag_range.inspect} must be a PEP 440 specifier set"
      end
      py_range = toml_str(dependencies["python"]?)
      if !py_range.empty? && !py_range.matches?(SPECIFIER_RE)
        violations << "dependencies.python #{py_range.inspect} must be a PEP 440 specifier set"
      end
      python_deps = toml_str_list(dependencies["python-deps"]?, "dependencies.python-deps", violations)

      pack_deps = toml_dep_table(dependencies, "packs", violations)
      optional_pack_deps = toml_dep_table(dependencies, "optional-packs", violations)

      object_types = toml_str_list(surface["object_types"]?, "surface.object_types", violations)
      relation_types = toml_str_list(surface["relation_types"]?, "surface.relation_types", violations)
      behaviors = toml_str_list(surface["behaviors"]?, "surface.behaviors", violations)
      tools = toml_str_list(surface["tools"]?, "surface.tools", violations)
      settings_schema = toml_str(surface["settings_schema"]?)

      capabilities = [] of CapabilityDecl
      surface["capabilities"]?.try do |caps|
        raw_list = caps.raw.is_a?(Array(TOML::Any)) ? caps.raw.as(Array(TOML::Any)) : [] of TOML::Any
        raw_list.each_with_index do |cap, i|
          unless cap.raw.is_a?(Hash(String, TOML::Any))
            violations << "surface.capabilities[#{i}] must be a table"
            next
          end
          h = cap.raw.as(Hash(String, TOML::Any))
          risk = toml_str(h["risk_class"]?)
          unless RISK_CLASSES.includes?(risk)
            violations << "surface.capabilities[#{i}].risk_class #{risk.inspect} must be one of low|medium|high|critical"
          end
          action = toml_str(h["action_class"]?)
          if !action.empty? && !ACTION_CLASSES.includes?(action)
            violations << "surface.capabilities[#{i}].action_class #{action.inspect} must be one of R0|R1|R2|R3|R4 (or absent)"
          end
          capabilities << CapabilityDecl.new(
            provider: toml_str(h["provider"]?),
            capability: toml_str(h["capability"]?),
            risk_class: risk,
            credential_ref: toml_str(h["credential_ref"]?),
            action_class: action,
          )
        end
      end

      consumes = toml_str_list(surface["consumes"]?, "surface.consumes", violations)

      fixtures_entrypoint = toml_str(fixtures["entrypoint"]?)
      violations << "fixtures.entrypoint must be nonempty" if fixtures_entrypoint.empty?
      fixtures_deterministic = toml_bool(fixtures["deterministic"]?)
      if fixtures["deterministic"]?.nil?
        violations << "fixtures.deterministic must be a boolean"
      end

      unless violations.empty?
        raise PackManifestError.new(p, violations)
      end

      PackManifest.new(
        name: name, version: version, description: description, license: license_,
        authored_by: authored_by, content_hash: content_hash,
        activegraph_range: ag_range, python_range: py_range,
        python_deps: python_deps, pack_deps: pack_deps,
        optional_pack_deps: optional_pack_deps,
        object_types: object_types, relation_types: relation_types,
        behaviors: behaviors, tools: tools, settings_schema: settings_schema,
        capabilities: capabilities, consumes: consumes,
        fixtures_entrypoint: fixtures_entrypoint,
        fixtures_deterministic: fixtures_deterministic, raw: data,
      )
    end

    # Two-way surface check between a manifest and a live Pack: every declared
    # name must exist on the Pack and every registered name must be declared,
    # for object_types / relation_types / behaviors / tools / settings_schema.
    # Capabilities are keyed by (provider, capability) and must agree on
    # risk_class / action_class. Raises PackManifestError with the full
    # mismatch list. `consumes` stays out of scope (imperative wiring).
    def self.verify_surface(manifest : PackManifest, pack : Pack) : Nil
      violations = [] of String

      if manifest.name != pack.name
        violations << "pack.name #{manifest.name.inspect} != Pack(name=#{pack.name.inspect})"
      end
      if manifest.version != pack.version
        violations << "pack.version #{manifest.version.inspect} != Pack(version=#{pack.version.inspect})"
      end

      two_way(violations, "object_types", manifest.object_types, pack.object_types.map(&.name))
      two_way(violations, "relation_types", manifest.relation_types, pack.relation_types.map(&.name))
      two_way(violations, "behaviors", manifest.behaviors, pack.behaviors.map(&.name))
      two_way(violations, "tools", manifest.tools, pack.tools.map(&.name))

      actual_settings = pack.settings_schema == "EmptySettings" ? "" : pack.settings_schema
      if manifest.settings_schema != actual_settings
        violations << "settings_schema: declared #{manifest.settings_schema.inspect}, Pack has #{actual_settings.inspect}"
      end

      declared_caps = manifest.capabilities.to_h { |capability| {"#{capability.provider}.#{capability.capability}", capability} }
      actual_caps = pack.capabilities.to_h { |capability| {"#{capability.provider}.#{capability.capability}", capability} }
      (declared_caps.keys.to_set - actual_caps.keys.to_set).to_a.sort.each do |key|
        violations << "capabilities: declared #{key} not on Pack"
      end
      (actual_caps.keys.to_set - declared_caps.keys.to_set).to_a.sort.each do |key|
        violations << "capabilities: Pack declares #{key} undeclared in manifest"
      end
      (declared_caps.keys.to_set & actual_caps.keys.to_set).to_a.sort.each do |key|
        d = declared_caps[key]
        a = actual_caps[key]
        if d.risk_class != a.risk_class
          violations << "capabilities: #{key} risk_class mismatch — manifest #{d.risk_class.inspect}, Pack #{a.risk_class.inspect}"
        end
        if d.action_class != a.action_class
          violations << "capabilities: #{key} action_class mismatch — manifest #{d.action_class.inspect}, Pack #{a.action_class.inspect}"
        end
      end

      unless violations.empty?
        raise PackManifestError.new("#{manifest.name}@#{manifest.version}", violations)
      end
    end

    # The spec §4 canonical content hash over a pack directory, byte-exact.
    # `manifest.toml` is EXCLUDED (a hash cannot cover itself). Symlinks and
    # non-UTF-8/NFC paths are rejected loudly. Returns "sha256:" + 64 hex.
    def self.compute_content_hash(pack_root : String) : String
      hash_pack_dir(pack_root, include_manifest: false)
    end

    # The bundle hash external pins use: the §4 walk WITH manifest.toml.
    def self.compute_bundle_hash(pack_root : String) : String
      hash_pack_dir(pack_root, include_manifest: true)
    end

    def self.verify_bundle_hash(expected : String, pack_root : String) : Nil
      if !expected.starts_with?(HASH_PREFIX) || !expected[HASH_PREFIX.size..].matches?(HEX64_RE)
        raise PackManifestError.new(
          pack_root,
          ["external pin #{expected.inspect} must be 'sha256:' + 64 lowercase hex chars"]
        )
      end
      actual = compute_bundle_hash(pack_root)
      if actual != expected
        raise PackManifestError.new(
          pack_root,
          ["bundle hash mismatch: external pin is #{expected}, directory (manifest included) hashes to #{actual}"]
        )
      end
    end

    def self.verify_content_hash(manifest : PackManifest, pack_root : String) : Nil
      actual = compute_content_hash(pack_root)
      if actual != manifest.content_hash
        raise PackManifestError.new(
          pack_root,
          ["content hash mismatch: manifest pins #{manifest.content_hash}, directory hashes to #{actual}"]
        )
      end
    end

    private def self.hash_pack_dir(pack_root : String, *, include_manifest : Bool) : String
      unless File.directory?(pack_root)
        raise PackManifestError.new(pack_root, ["pack root is not a directory"])
      end

      entries = [] of {String, String}
      violations = [] of String
      root = File.expand_path(pack_root)

      walk = uninitialized Proc(String, Nil)
      walk = ->(dir : String) {
        Dir.children(dir).sort.each do |child_name|
          child = File.join(dir, child_name)
          next if child_name.starts_with?('.')

          rel = child[root.size..].lstrip('/')
          if File.symlink?(child)
            violations << "symlink rejected: #{rel}"
            next
          end
          if rel.unicode_normalize(:nfc) != rel
            violations << "path not NFC-normalized: #{rel.inspect}"
            next
          end
          if File.directory?(child)
            next if child_name == "__pycache__"
            walk.call(child)
            next
          end
          if File.file?(child)
            next if child_name.ends_with?(".pyc")
            next if rel == "manifest.toml" && !include_manifest
            entries << {rel, child}
          end
        end
      }
      walk.call(root)

      unless violations.empty?
        raise PackManifestError.new(pack_root, violations)
      end

      hex = Digest::SHA256.hexdigest do |ctx|
        entries.sort_by! { |rel, _| rel.to_slice }
        entries.each do |rel, child|
          bytes = Bytes.new(File.size(child))
          File.open(child, "rb", &.read_fully(bytes))
          ctx.update(rel.to_slice)
          ctx.update(Bytes.new(1, 0_u8))
          len_bytes = Bytes.new(8)
          IO::ByteFormat::BigEndian.encode(bytes.size.to_u64, len_bytes)
          ctx.update(len_bytes)
          ctx.update(bytes)
        end
      end
      "#{HASH_PREFIX}#{hex}"
    end

    private def self.table(data : Hash(String, TOML::Any), key : String, violations : Array(String)) : Hash(String, TOML::Any)
      v = data[key]?
      if v.nil? || !v.raw.is_a?(Hash(String, TOML::Any))
        violations << "missing required table [#{key}]"
        return {} of String => TOML::Any
      end
      v.raw.as(Hash(String, TOML::Any))
    end

    private def self.table_like(
      parent : Hash(String, TOML::Any),
      key : String,
      label : String,
      violations : Array(String),
    ) : Hash(String, TOML::Any)
      v = parent[key]?
      if v.nil? || !v.raw.is_a?(Hash(String, TOML::Any))
        violations << "missing required table #{label}"
        return {} of String => TOML::Any
      end
      v.raw.as(Hash(String, TOML::Any))
    end

    private def self.toml_str(value : TOML::Any?) : String
      return "" if value.nil?
      case raw = value.raw
      when String  then raw
      when Int64   then raw.to_s
      when Float64 then raw.to_s
      when Bool    then raw.to_s
      else
        ""
      end
    end

    private def self.toml_bool(value : TOML::Any?) : Bool
      return false if value.nil?
      raw = value.raw
      raw.is_a?(Bool) && raw
    end

    private def self.toml_str_list(
      value : TOML::Any?,
      label : String,
      violations : Array(String),
    ) : Array(String)
      if value.nil?
        # Absent keys default to an empty list (upstream `get(key, [])`).
        return [] of String
      end
      raw = value.raw
      unless raw.is_a?(Array(TOML::Any)) && raw.all? { |item| item.raw.is_a?(String) }
        violations << "#{label} must be a list of strings"
        return [] of String
      end
      raw.map { |item| item.raw.as(String) }
    end

    private def self.toml_dep_table(
      dependencies : Hash(String, TOML::Any),
      key : String,
      violations : Array(String),
    ) : Hash(String, String)
      value = dependencies[key]?
      if value.nil?
        return {} of String => String
      end
      raw = value.raw
      unless raw.is_a?(Hash(String, TOML::Any))
        violations << "dependencies.#{key} must be a table"
        return {} of String => String
      end
      out = {} of String => String
      raw.each do |k, v|
        spec = toml_str(v)
        if !spec.matches?(SPECIFIER_RE)
          violations << "dependencies.#{key}.#{k} #{spec.inspect} must be a PEP 440 specifier set"
          next
        end
        out[k] = spec
      end
      out
    end

    private def self.two_way(
      violations : Array(String),
      kind : String,
      declared : Array(String),
      actual : Array(String),
    ) : Nil
      actual_set = actual.to_set
      (declared.to_set - actual_set).to_a.sort.each do |name|
        violations << "#{kind}: declared '#{name}' not found on Pack"
      end
      (actual_set - declared.to_set).to_a.sort.each do |name|
        violations << "#{kind}: Pack registers '#{name}' undeclared"
      end
    end
  end
end
