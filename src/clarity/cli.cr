require "clip"
require "./routing_config"

module Clarity
  module CLI
    @[Clip::Doc("Clarity — log-primary Sans-IO agent runtime")]
    abstract struct Root
      include Clip::Mapper

      Clip.add_commands({
        "route"   => Route,
        "diff"    => DiffCmd,
        "log"     => Log,
        "replay"  => ReplayCmd,
        "session" => Session,
        "fork"    => ForkCmd,
        "chat"    => ChatCmd,
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

    @[Clip::Doc("Session management")]
    abstract struct Session < Root
      include Clip::Mapper

      Clip.add_commands({
        "list" => SessionList,
      })
    end

    @[Clip::Doc("Fork an event log at a given sequence point")]
    struct ForkCmd < Root
      include Clip::Mapper

      @[Clip::Option("-f", "--from")]
      getter from : String

      @[Clip::Option("-a", "--at")]
      getter at : Int64

      @[Clip::Option("-o", "--out")]
      getter output_path : String?
    end

    @[Clip::Doc("Start an interactive chat session")]
    struct ChatCmd < Root
      include Clip::Mapper
    end

    @[Clip::Doc("List saved sessions")]
    struct SessionList < Session
      include Clip::Mapper
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
      when SessionList
        execute_session_list(cmd, io)
      when ForkCmd
        execute_fork(cmd, io)
      when ChatCmd
        execute_chat(cmd, io)
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

    private def self.execute_chat(cmd : ChatCmd, io : IO) : Nil
      config = Config.load
      api_key = config.providers.fetch("deepseek", ProviderConfig.new).api_key

      unless api_key
        io.puts "ERROR: DEEPSEEK_API_KEY not set"
        io.puts "Set CLARITY_DEEPSEEK_API_KEY or add providers.deepseek.api_key to config"
        return
      end

      store = SQLiteEventStore.new(
        File.join(config.data_dir, "chat.db"),
        "chat_#{Time.utc.to_unix}",
      )

      begin
        client = Crig::Providers::DeepSeek::Client.new(api_key)
        model = client.completion_model(Crig::Providers::DeepSeek::DEEPSEEK_V4_FLASH)
        agent = Crig::Agent(Crig::Providers::DeepSeek::CompletionModel).new(
          model: model,
          preamble: "You are a helpful assistant.",
        )
        log_agent = LogAgent(Crig::Providers::DeepSeek::CompletionModel).new(agent, store: store)

        runtime = Runtime(Crig::Providers::DeepSeek::CompletionModel).new(
          store: store,
          log_agent: log_agent,
        )

        io.puts "Starting chat session..."
        TUI.run_with(runtime)
      rescue ex : Exception
        io.puts "ERROR: #{ex.message}"
      end
    end

    # Execute a chat with a pre-built Runtime (for testing).
    def self.execute_chat_with_runtime(runtime : Runtime(M)) forall M
      TUI.run_with(runtime)
    end

    private def self.execute_fork(cmd : ForkCmd, io : IO) : Nil
      source_log = EventLogCodec.decode(File.read(cmd.from))
      target_seq = cmd.at.to_u64

      fork = source_log.fork_at(target_seq)
      out_path = cmd.output_path || File.join(File.dirname(cmd.from), "fork_at_#{target_seq}.log")
      encoded = EventLogCodec.encode(fork)
      File.write(out_path, encoded)

      io.puts "Forked at sequence #{target_seq}"
      io.puts "  Source: #{cmd.from} (#{source_log.events.size} events)"
      io.puts "  Fork:   #{out_path} (#{fork.events.size} events)"
    rescue ex : File::NotFoundError
      io.puts "ERROR: file not found: #{cmd.from}"
    rescue ex : Clarity::InvalidLogEncodingError
      io.puts "ERROR: invalid event log: #{ex.message}"
    end

    private def self.execute_session_list(cmd : SessionList, io : IO) : Nil
      store = SessionStore.new(SessionStore.default_dir)
      sessions = store.list
      if sessions.empty?
        io.puts "No saved sessions in #{SessionStore.default_dir}"
        return
      end
      io.puts "Sessions in #{SessionStore.default_dir}:"
      sessions.each { |session_path| io.puts "  #{session_path}" }
    end

    private def self.execute_log_inspect(cmd : LogInspect, io : IO) : Nil
      store = SessionStore.new(SessionStore.default_dir).load_store(cmd.file)
      events = store.iter_events
      io.puts "Event log: #{cmd.file}"
      io.puts "Events:    #{events.size} (store count: #{store.count})"
      io.puts
      events.each do |evt|
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
      store = SessionStore.new(SessionStore.default_dir).load_store(cmd.file)
      events = store.iter_events
      log_events = EventLogCodec.decode(File.read(cmd.file))
      result = ReplayEngine.new.replay(events, ReplayMode::Permissive)
      io.puts "Replay complete"
      io.puts "  Events:      #{log_events.events.size}"
      io.puts "  Objects:     #{result.projection.objects.size}"
      io.puts "  Relations:   #{result.projection.relations.size}"
      io.puts "  Effects:     #{result.effects.size}"
    rescue ex : File::NotFoundError
      io.puts "ERROR: file not found: #{cmd.file}"
    rescue ex : Clarity::InvalidLogEncodingError
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
