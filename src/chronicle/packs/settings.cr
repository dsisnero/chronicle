module Chronicle
  module Packs
    # A settings schema is a `JSON::Serializable` struct that includes this
    # module. The macro generates the default-construction and
    # hash-validation helpers the pack loader uses, so a settings struct is
    # fully typed in behavior handlers while the loader deals in canonical
    # JSON. Mirrors activegraph's Pydantic `settings_schema` (CONTRACT v0.9 #7).
    module SettingsSchema
      macro included
        # Build the canonical settings hash from user input (or defaults when
        # input is nil). Raises PackSettingsMissingError on validation failure.
        # Always goes through from_json so required (default-less) fields are
        # enforced at runtime, mirroring Pydantic's required-field behavior.
        def self.build_pack_settings(input : JSON::Any?) : Hash(String, JSON::Any)
          json = input.nil? ? "{}" : input.to_json
          validated = begin
            from_json(json).to_json
          rescue ex : JSON::ParseException | TypeCastError
            raise ::Chronicle::Packs::PackSettingsMissingError.new(
              "settings failed validation: #{ex.message}"
            )
          end
          ::Chronicle::Packs::Settings.canonicalize(validated)
        end

        # The settings class name (short form, matching upstream `__name__`),
        # used for the pack manifest's two-way surface check.
        def self.pack_settings_name : String
          {{ @type.name.stringify.split("::").last }}
        end
      end
    end

    # No-settings placeholder. Packs whose `settings_schema` is this struct
    # load bare and their behaviors still get a real (empty) settings value.
    struct EmptySettings
      include JSON::Serializable
      include SettingsSchema
    end

    # JSON canonicalization helpers for settings values.
    module Settings
      extend self

      def canonicalize(json : String) : Hash(String, JSON::Any)
        raw = sort_json(JSON.parse(json))
        raw.raw.as(Hash(String, JSON::Any))
      end

      def sort_json(value : JSON::Any) : JSON::Any
        case raw = value.raw
        when Hash(String, JSON::Any)
          JSON::Any.new(raw.keys.sort!.to_h { |k| {k, sort_json(raw[k])} })
        when Array(JSON::Any)
          JSON::Any.new(raw.map { |v| sort_json(v) })
        else
          value
        end
      end
    end
  end
end
