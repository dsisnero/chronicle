require "digest/sha256"
require "toml"

module Chronicle
  module Packs
    # A versioned, content-hashed prompt. `content_hash` is the SHA-256 of the
    # body truncated to 16 hex chars; this is the replay contract (the hash,
    # not the declared version — CONTRACT v0.9 #10).
    struct PackPrompt
      getter name : String
      getter version : String
      getter body : String
      getter content_hash : String

      def initialize(@name : String, @version : String, @body : String, @content_hash : String)
      end

      def self.compute_hash(body : String) : String
        "sha256:#{Digest::SHA256.hexdigest(body)[0, 16]}"
      end

      def self.from_body(name : String, version : String, body : String) : PackPrompt
        new(name: name, version: version, body: body, content_hash: compute_hash(body))
      end
    end

    # Scan a directory of `*.md` prompt files with TOML frontmatter:
    #
    #     ---
    #     version = "1.0.0"
    #     name = "optional_name"   # defaults to filename without .md
    #     ---
    #     <body>
    #
    # Returns prompts sorted by name. Content hash is computed over the body
    # exactly as it will appear at runtime. Raises PackPromptLoadError on
    # missing/malformed frontmatter, a missing `version`, a duplicate prompt
    # name, or I/O failure. Hidden files and symlinks are skipped.
    def self.load_prompts_from_dir(path : String) : Array(PackPrompt)
      dir = File.expand_path(path)
      raise PackPromptLoadError.new("prompts directory does not exist: #{path}") unless File.exists?(dir)
      raise PackPromptLoadError.new("prompts path is not a directory: #{path}") unless File.directory?(dir)

      out = {} of String => PackPrompt
      Dir.glob(File.join(dir, "*.md")).sort.each do |md_path|
        name = File.basename(md_path)
        next if name.starts_with?(".")
        next if File.symlink?(md_path)

        prompt = load_one_prompt(md_path)
        if out.has_key?(prompt.name)
          raise PackPromptLoadError.new("duplicate prompt name #{prompt.name.inspect} (file: #{md_path})")
        end
        out[prompt.name] = prompt
      end
      out.values.sort_by!(&.name)
    end

    # Parses `---`-delimited TOML frontmatter. Mirrors activegraph's
    # `_FRONTMATTER_RE` (`\A---\s*\n(.*?)\n---\s*\n(.*)\Z`, DOTALL).
    FRONTMATTER_RE = /(?s)\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n(.*)\z/

    private def self.load_one_prompt(md_path : String) : PackPrompt
      text = begin
        File.read(md_path, encoding: "utf-8")
      rescue ex : IO::Error | File::Error
        raise PackPromptLoadError.new("cannot read #{md_path}: #{ex.message}")
      end

      m = text.match(FRONTMATTER_RE)
      if m.nil?
        raise PackPromptLoadError.new(
          "#{md_path}: missing TOML frontmatter (file must start with '---' line)"
        )
      end
      fm_text = m[1]
      body = m[2]
      fm = begin
        TOML.parse(fm_text)
      rescue ex : TOML::ParseException
        raise PackPromptLoadError.new("#{md_path}: frontmatter is not valid TOML: #{ex.message}")
      end
      version_value = fm["version"]?
      if version_value.nil?
        raise PackPromptLoadError.new("#{md_path}: frontmatter missing required 'version' key")
      end
      version = toml_scalar_string(version_value)
      name_value = fm["name"]?
      name = if name_value
               toml_scalar_string(name_value)
             else
               File.basename(md_path, ".md")
             end
      PackPrompt.from_body(name: name, version: version, body: body)
    end

    private def self.toml_scalar_string(value : TOML::Any) : String
      case raw = value.raw
      when String  then raw
      when Int64   then raw.to_s
      when Float64 then raw.to_s
      when Bool    then raw.to_s
      else
        value.to_s
      end
    end
  end
end
