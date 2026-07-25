require "yaml"

module Clarity
  module Routing
    # Convenience loader for routing configuration from YAML/JSON files.
    # This module sits at the config-boundary layer — it reads files and
    # converts them into core Policy structs.
    module Config
      extend self

      # Load a Policy from a YAML or JSON file.
      def from_file(path : String) : Policy
        content = File.read(path)
        if path.ends_with?(".json")
          Policy.from_json(content)
        else
          from_yaml(content)
        end
      end

      # Load a Policy from a YAML string.
      def from_yaml(yaml : String) : Policy
        parsed = YAML.parse(yaml)
        Policy.from_json(parsed.to_json)
      end
    end
  end
end
