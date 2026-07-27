require "yaml"

module Clarity
  struct ProviderConfig
    # The adapter family (for example `ollama` or `openai_compatible`). This
    # is deliberately independent of the providers hash key, which is the
    # stable named provider instance used by routes.
    getter type : String
    getter api_key : String?
    getter api_key_env : String?
    getter base_url : String?
    getter? local : Bool
    getter? disabled : Bool

    def initialize(
      @type : String = "unknown",
      @api_key : String? = nil,
      @api_key_env : String? = nil,
      @base_url : String? = nil,
      @local : Bool = false,
      @disabled : Bool = false,
    )
    end

    # Credential resolution is an edge concern. The core receives only the
    # resulting availability snapshot, never this value or its source.
    def resolved_api_key : String?
      @api_key || @api_key_env.try { |name| ENV[name]? }
    end

    def credential_available? : Bool
      @local || !resolved_api_key.nil?
    end

    def with_type(type : String) : self
      self.class.new(type, @api_key, @api_key_env, @base_url, @local, @disabled)
    end

    def self.from_json(string_or_io : String | IO) : self
      obj = JSON.parse(string_or_io).as_h
      new(
        type: obj.fetch("type", JSON::Any.new("unknown")).as_s,
        api_key: obj["api_key"]?.try(&.as_s),
        api_key_env: obj["api_key_env"]?.try(&.as_s),
        base_url: obj["base_url"]?.try(&.as_s),
        local: obj.fetch("local", JSON::Any.new(false)).as_bool,
        disabled: obj.fetch("disabled", JSON::Any.new(false)).as_bool,
      )
    end
  end

  struct Config
    getter data_dir : String
    getter providers : Hash(String, ProviderConfig)
    getter routing_config : String?
    getter? debug : Bool

    def initialize(
      @data_dir : String = "",
      @providers : Hash(String, ProviderConfig) = {} of String => ProviderConfig,
      @routing_config : String? = nil,
      @debug : Bool = false,
    )
    end

    def self.from_file(path : String) : self
      from_yaml_string(File.read(path))
    end

    def self.from_yaml(yaml : String) : self
      from_yaml_string(yaml)
    end

    def self.merge(global : Config, local : Config) : Config
      merged_providers = global.providers.merge(local.providers) { |_key, _global_val, local_val| local_val }
      result_data_dir = local.data_dir.empty? ? global.data_dir : local.data_dir
      result_routing = local.routing_config || global.routing_config
      result_debug = local.data_dir.empty? ? global.debug? : local.debug?
      Config.new(result_data_dir, merged_providers, result_routing, result_debug)
    end

    def apply_env_overrides : self
      Config.env_overrides(self)
    end

    def self.env_overrides(base : Config) : Config
      provs = base.providers.dup

      {"deepseek" => "DEEPSEEK", "openai" => "OPENAI", "anthropic" => "ANTHROPIC"}.each do |key, env_name|
        # Check namespaced (CLARITY_*) first, then bare env var
        ev = ENV["CLARITY_#{env_name}_API_KEY"]? || ENV["#{env_name}_API_KEY"]?
        if ev && !ev.empty?
          existing = provs.fetch(key, ProviderConfig.new)
          provs[key] = ProviderConfig.new(
            type: existing.type,
            api_key: ev,
            api_key_env: existing.api_key_env,
            base_url: existing.base_url,
            local: existing.local?,
            disabled: existing.disabled?,
          )
        end
      end

      dbg = base.debug?
      dbe = ENV["CLARITY_DEBUG"]?
      dbg = true if dbe == "true" || dbe == "1"

      Config.new(base.data_dir, provs, base.routing_config, dbg)
    end

    def self.load(working_dir : String? = nil) : Config
      result = Config.new

      global_path = File.join(ENV["HOME"]? || ".", ".clarity", "config.yml")
      if File.exists?(global_path)
        result = Config.merge(result, Config.from_yaml(File.read(global_path)))
      end

      local_dir = working_dir || Dir.current
      local_path = File.join(local_dir, ".clarity.yml")
      if File.exists?(local_path)
        result = Config.merge(result, Config.from_yaml(File.read(local_path)))
      end

      result.apply_env_overrides
    end

    def self.from_json(string_or_io : String | IO) : self
      obj = JSON.parse(string_or_io).as_h
      data_dir = obj.fetch("data_dir", JSON::Any.new("")).as_s
      routing_config = obj["routing_config"]?.try(&.as_s)
      debug = obj.fetch("debug", JSON::Any.new(false)).as_bool
      providers = {} of String => ProviderConfig
      if provs = obj["providers"]?
        if provs.raw.nil?
          # nil/empty providers
        else
          provs.as_h.each do |key, val|
            provider = ProviderConfig.from_json(val.to_json)
            providers[key] = provider.type == "unknown" ? provider.with_type(infer_provider_type(key)) : provider
          end
        end
      end
      new(data_dir, providers, routing_config, debug)
    end

    private def self.from_yaml_string(yaml : String) : self
      from_json(YAML.parse(yaml).to_json)
    end

    private def self.infer_provider_type(instance_id : String) : String
      return "openai_compatible" if instance_id.starts_with?("openai-compat:")
      instance_id
    end
  end
end
