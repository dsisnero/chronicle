require "clip"
require "./routing_config"

module Clarity
  module CLI
    @[Clip::Doc("Clarity — log-primary Sans-IO agent runtime")]
    abstract struct Root
      include Clip::Mapper

      Clip.add_commands({
        "route"  => Route,
        "diff"   => DiffCmd,
        "log"    => Log,
        "replay" => ReplayCmd,
      })
    end

    @[Clip::Doc("Routing commands")]
    abstract struct Route < Root
      include Clip::Mapper

      Clip.add_commands({
        "preview" => RoutePreview,
      })
    end

    @[Clip::Doc("Compare two event logs and show structural diff")]
    struct DiffCmd < Root
      include Clip::Mapper

      @[Clip::Option("-a", "--before")]
      getter before : String

      @[Clip::Option("-b", "--after")]
      getter after : String
    end

    @[Clip::Doc("Log inspection commands")]
    abstract struct Log < Root
      include Clip::Mapper

      Clip.add_commands({
        "inspect" => LogInspect,
      })
    end

    @[Clip::Doc("Show events in a log file")]
    struct LogInspect < Log
      include Clip::Mapper

      @[Clip::Option("-f", "--file")]
      getter file : String
    end

    @[Clip::Doc("Replay an event log and show results")]
    struct ReplayCmd < Root
      include Clip::Mapper

      @[Clip::Option("-f", "--file")]
      getter file : String
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
      when DiffCmd
        execute_diff(cmd, io)
      when LogInspect
        execute_log_inspect(cmd, io)
      when ReplayCmd
        execute_replay(cmd, io)
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

    private def self.execute_log_inspect(cmd : LogInspect, io : IO) : Nil
      log = EventLogCodec.decode(File.read(cmd.file))
      io.puts "Event log: #{cmd.file}"
      io.puts "Events:    #{log.events.size}"
      io.puts
      log.events.each do |evt|
        io.puts "  [#{evt.sequence}] #{evt.type} (#{evt.id})"
        io.puts "    actor: #{evt.actor}, time: #{evt.timestamp}"
        io.puts "    payload: #{evt.payload}"
        io.puts
      end
    rescue ex : File::NotFoundError
      io.puts "ERROR: file not found: #{cmd.file}"
    rescue ex : InvalidLogEncodingError
      io.puts "ERROR: invalid event log: #{ex.message}"
    end

    private def self.execute_replay(cmd : ReplayCmd, io : IO) : Nil
      log = EventLogCodec.decode(File.read(cmd.file))
      result = ReplayEngine.new.replay(log.events, ReplayMode::Permissive)
      io.puts "Replay complete"
      io.puts "  Events:      #{log.events.size}"
      io.puts "  Objects:     #{result.projection.objects.size}"
      io.puts "  Relations:   #{result.projection.relations.size}"
      io.puts "  Effects:     #{result.effects.size}"
    rescue ex : File::NotFoundError
      io.puts "ERROR: file not found: #{cmd.file}"
    rescue ex : InvalidLogEncodingError
      io.puts "ERROR: invalid event log: #{ex.message}"
    rescue ex : ReplayDivergenceError
      io.puts "ERROR: replay diverged: #{ex.message}"
    end

    private def self.execute_diff(cmd : DiffCmd, io : IO) : Nil
      before_log = EventLogCodec.decode(File.read(cmd.before))
      after_log = EventLogCodec.decode(File.read(cmd.after))

      before_proj = GraphProjection.replay(before_log.events)
      after_proj = GraphProjection.replay(after_log.events)

      diff = after_proj.diff(before_proj)
      DiffFormatter.format(diff, io)
    rescue ex : File::NotFoundError
      io.puts "ERROR: file not found: #{ex.message}"
    rescue ex : InvalidLogEncodingError
      io.puts "ERROR: invalid event log: #{ex.message}"
    end
  end
end
