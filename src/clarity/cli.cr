require "clip"
require "./routing_config"

module Clarity
  module CLI
    @[Clip::Doc("Clarity — log-primary Sans-IO agent runtime")]
    abstract struct Root
      include Clip::Mapper

      Clip.add_commands({
        "route" => Route,
      })
    end

    @[Clip::Doc("Routing commands")]
    abstract struct Route < Root
      include Clip::Mapper

      Clip.add_commands({
        "preview" => RoutePreview,
      })
    end

    @[Clip::Doc("Preview a routing decision without executing a model")]
    struct RoutePreview < Route
      include Clip::Mapper

      @[Clip::Option("-c", "--config")]
      getter config : String

      @[Clip::Option("-t", "--text")]
      getter text : String

      @[Clip::Option("-i", "--intent")]
      getter intent : String?
    end

    def self.run(args : Array(String) = ARGV) : String
      io = IO::Memory.new
      exec(args, io)
      io.to_s
    end

    def self.exec(args : Array(String), io : IO) : Nil
      cmd = Root.parse(args)
      case cmd
      when RoutePreview
        execute_route_preview(cmd, io)
      else
        io.puts Root.help
      end
    rescue ex : Clip::MissingCommand
      io.puts Root.help
    rescue ex : Clip::Error
      io.puts "ERROR: #{ex.message}"
    end

    private def self.execute_route_preview(cmd : RoutePreview, io : IO) : Nil
      begin
        policy = Routing::Config.from_file(cmd.config)
      rescue ex : File::NotFoundError
        io.puts "ERROR: config file not found: #{cmd.config}"
        return
      rescue ex : Exception
        io.puts "ERROR: invalid config: #{ex.message}"
        return
      end

      intent = cmd.intent.try { |name| Routing::Intent.parse(name) }
      request = Routing::Request.new(
        cmd.text,
        intent,
        nil,
        [] of String,
        [] of Routing::ContextCandidate,
        nil,
        50,
      )

      begin
        available = policy.configured_targets
        decision = Routing::Router.new.preview(request, policy, available)

        io.puts "Route Decision:"
        io.puts "  Intent:     #{decision.intent}"
        io.puts "  Rule:       #{decision.matched_rule}"
        io.puts "  Model:      #{decision.target.provider}/#{decision.target.model}"
        io.puts "  Override:   #{decision.override_used?}"
        io.puts "  Fallback:   #{decision.fallback_used?}"
        io.puts "  Confidence: #{(decision.classification.confidence * 100).to_i}%"
        io.puts "  Trace:      #{decision.routing_reason}"
      rescue ex : NoRouteError
        io.puts "ERROR: no eligible route"
      rescue ex : InvalidRoutingPolicyError
        io.puts "ERROR: #{ex.message}"
      end
    end
  end
end
