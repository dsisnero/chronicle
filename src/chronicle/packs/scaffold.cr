module Chronicle
  module Packs
    # `pack new <name>` scaffolding. Generates a runnable Crystal package
    # layout that declares a Pack via the annotations DSL and registers it
    # with the discovery registry. Mirrors activegraph/packs/scaffold.py
    # (CONTRACT v0.9 #14).
    module Scaffold
      extend self

      SCAFFOLD_NAME_RE = /^[a-z][a-z0-9-]*$/

      # Return {directory_name, module_name}: kebab → snake for the module
      # name (like Python's distribution-vs-import name split).
      def normalize_pack_name(raw : String) : {String, String}
        name = raw.strip.downcase
        unless name.matches?(SCAFFOLD_NAME_RE)
          raise ArgumentError.new(
            "pack name #{raw.inspect} must match [a-z][a-z0-9-]* (lowercase, ASCII)"
          )
        end
        {name, name.gsub('-', '_')}
      end

      # Generate the pack at `target_dir / pack_name`. Returns the created
      # path. Raises File::AlreadyExistsError if the directory exists.
      def scaffold_pack(target_dir : String, raw_name : String) : String
        pack_name, module_name = normalize_pack_name(raw_name)
        root = File.join(target_dir, pack_name)
        raise File::AlreadyExistsError.new("file exists: #{root}", file: root) if File.exists?(root)
        raise ArgumentError.new("#{target_dir} is not a directory") unless File.directory?(target_dir)

        Dir.mkdir_p(File.join(root, module_name, "prompts"))
        Dir.mkdir_p(File.join(root, "spec"))

        files = {
          File.join(root, "shard.yml")                                 => shard_template(pack_name),
          File.join(root, "README.md")                                 => readme_template(pack_name),
          File.join(root, "#{module_name}.cr")                         => pack_init_template(module_name),
          File.join(root, module_name, "version.cr")                   => version_template(module_name),
          File.join(root, module_name, "settings.cr")                  => settings_template(module_name),
          File.join(root, module_name, "object_types.cr")              => object_types_template(module_name),
          File.join(root, module_name, "behaviors.cr")                 => behaviors_template(module_name),
          File.join(root, module_name, "tools.cr")                     => tools_template(module_name),
          File.join(root, module_name, "prompts", "example_prompt.md") => prompt_template,
          File.join(root, "spec", "#{module_name}_spec.cr")            => smoke_test_template(module_name),
        }
        files.each do |path, content|
          File.write(path, content)
        end
        root
      end

      private def title(name : String) : String
        name.split('_').map(&.capitalize).join
      end

      private def shard_template(pack_name : String) : String
        <<-SHARD
        name: #{pack_name}
        version: 0.1.0

        dependencies:
          chronicle:
            github: dsisnero/chronicle

        targets:
          #{pack_name}:
            main: #{pack_name}.cr
        SHARD
      end

      private def readme_template(pack_name : String) : String
        <<-MD
        # #{pack_name}

        A [Chronicle](https://github.com/dsisnero/chronicle) pack.

        ## Use

        ```crystal
        require "chronicle"
        require "#{pack_name}"

        pack = #{pack_name}::PACK
        ```
        MD
      end

      private def pack_init_template(module_name : String) : String
        titled = title(module_name)
        <<-CR
        require "chronicle"

        require "./#{module_name}/version"
        require "./#{module_name}/settings"
        require "./#{module_name}/object_types"
        require "./#{module_name}/behaviors"
        require "./#{module_name}/tools"

        # #{module_name} — a Chronicle pack.
        module #{titled}
          include Chronicle::Packs::DSL

          pack(
            name: "#{module_name}",
            version: "0.1.0",
            description: "A Chronicle pack.",
            settings_schema: #{titled}Settings,
          )
        end

        # The pack manifest, exported for discovery/loading.
        PACK = #{titled}::PACK
        CR
      end

      private def version_template(module_name : String) : String
        <<-CR
        module #{title(module_name)}
          VERSION = "0.1.0"
        end
        CR
      end

      private def settings_template(module_name : String) : String
        <<-CR
        require "json"

        # Settings model for the pack. Behaviors access it via a typed
        # `settings` parameter or `ctx.settings`. All fields should carry
        # defaults so `runtime.load_pack(pack)` works without `settings=`.
        module #{title(module_name)}
          struct #{title(module_name)}Settings
            include JSON::Serializable
            include Chronicle::Packs::SettingsSchema

            getter threshold : Float64 = 0.5
          end
        end
        CR
      end

      private def object_types_template(module_name : String) : String
        <<-CR
        require "json"

        # Object types declared by this pack. The @[ObjectType] annotation
        # makes the DSL collect the schema for load-time validation.
        module #{title(module_name)}
          @[Chronicle::Packs::ObjectType(name: "item")]
          struct Item
            include JSON::Serializable

            getter name : String
            getter notes : String = ""
          end
        end
        CR
      end

      private def behaviors_template(module_name : String) : String
        <<-CR
        require "chronicle"

        # Pack behaviors. The @[Chronicle::Packs::Behavior] annotation does
        # NOT register globally (CONTRACT v0.9 #3); the DSL collects it.
        module #{title(module_name)}
          @[Chronicle::Packs::Behavior(name: "hello", on: ["goal.created"])]
          def self.hello(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
            graph.add_object("item", %({"name":"hello world"}), caused_by: event.id)
          end
        end
        CR
      end

      private def tools_template(module_name : String) : String
        <<-CR
        require "chronicle"

        # Pack-scoped tools. Registered with the `{pack}.{name}` canonical
        # form when the pack loads; `export_globally: true` also registers
        # the short form.
        module #{title(module_name)}
          @[Chronicle::Packs::Tool(name: "search", description: "Example search tool.")]
          def self.search(args : String) : String
            %({"results":[]})
          end
        end
        CR
      end

      private def prompt_template : String
        <<-MD
        ---
        version = "1.0.0"
        ---
        You are an example behavior. Replace this prompt with your own.

        Content is hashed for replay determinism — if you edit this prompt,
        the hash changes even if you forget to bump the declared version.
        MD
      end

      private def smoke_test_template(module_name : String) : String
        titled = title(module_name)
        <<-CR
        require "spec"
        require "chronicle"
        require "../#{module_name}"

        # The pack imports without global side effects and its manifest is
        # discoverable (CONTRACT v0.9 #3 / #14).
        describe "#{module_name} pack" do
          it "exports a manifest and registers for discovery" do
            pack = #{titled}::PACK
            pack.name.should eq("#{module_name}")
            pack.version.should eq("0.1.0")

            found = Chronicle::Packs.discover.any? { |d| d.name == "#{module_name}" }
            found.should be_true
          end
        end
        CR
      end
    end
  end
end
