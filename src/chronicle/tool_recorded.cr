require "json"
require "digest/sha256"

module Chronicle
  # Fixture-based tool invokers for tests (CONTRACT v0.7 #15). Mirrors
  # activegraph.llm.recorded. Fixtures live at
  # `<dir>/<tool_name>/<args_hash>.json`, with `recorded_at` outside the
  # hashed args.
  #
  #   RecordedToolProvider  — reads the fixture, returns the cached response.
  #                           Missing fixtures raise ToolError
  #                           (reason `tool.fixture_missing`).
  #   RecordingToolProvider — wraps an inner invoker, calls the real thing,
  #                           persists the response as a fixture.
  #   DirectToolInvoker     — the default invoker: calls the tool body with
  #                           timing and exception trapping (production path).
  module ToolRecorded
    extend self

    def now_iso : String
      RuntimeReason.now_iso
    end
  end

  # Read-only fixture invoker. Tests use this so they never call out.
  class RecordedToolProvider
    getter fixtures_dir : String

    def initialize(@fixtures_dir : String)
    end

    def invoke(tool : Tool, args : String) : CachedToolResponse
      args_hash = ToolCache.hash_tool_call(tool.name, args)
      path = File.join(@fixtures_dir, tool.name, "#{args_hash}.json")
      unless File.exists?(path)
        raise ToolError.new(
          "tool.fixture_missing",
          "no recorded fixture for tool=#{tool.name.inspect} " \
          "args_hash=#{args_hash} in #{@fixtures_dir}",
          {
            "tool"         => JSON::Any.new(tool.name),
            "args_hash"    => JSON::Any.new(args_hash),
            "fixtures_dir" => JSON::Any.new(@fixtures_dir),
          },
        )
      end
      data = JSON.parse(File.read(path)).as_h
      CachedToolResponse.new(
        output: data["output"]?.try(&.to_json) || "null",
        error: data["error"]?.try(&.as_h?),
        latency_seconds: data["latency_seconds"]?.try(&.as_f) || 0.0,
        cost_usd: data["cost_usd"]?.try(&.as_s?) || "0",
      )
    end
  end

  # Wraps an inner invoker and persists each response as a fixture.
  class RecordingToolProvider
    getter inner : DirectToolInvoker
    getter fixtures_dir : String

    def initialize(@inner : DirectToolInvoker, @fixtures_dir : String)
      Dir.mkdir_p(@fixtures_dir)
    end

    def invoke(tool : Tool, args : String) : CachedToolResponse
      response = @inner.invoke(tool, args)
      args_hash = ToolCache.hash_tool_call(tool.name, args)
      fixture_dir = File.join(@fixtures_dir, tool.name)
      Dir.mkdir_p(fixture_dir)
      path = File.join(fixture_dir, "#{args_hash}.json")
      fixture = {
        "tool"            => JSON::Any.new(tool.name),
        "args_hash"       => JSON::Any.new(args_hash),
        "recorded_at"     => JSON::Any.new(ToolRecorded.now_iso),
        "args"            => JSON.parse(ToolCache.canonicalize_args(args)),
        "output"          => JSON.parse(response.output),
        "error"           => JSON::Any.new(response.error.nil? ? nil : response.error),
        "latency_seconds" => JSON::Any.new(response.latency_seconds),
        "cost_usd"        => JSON::Any.new(response.cost_usd),
      }
      File.write(path, Prompt.canonical_json(JSON::Any.new(fixture), spaced: true))
      response
    end
  end

  # The default invoker: calls the tool body with timing and exception
  # trapping. The runtime uses this when no provider wrapper is in play.
  class DirectToolInvoker
    def invoke(tool : Tool, args : String) : CachedToolResponse
      t0 = Time.instant
      begin
        result = tool.call(args)
      rescue error : ToolError
        raise error
      rescue error : Exception
        raise ToolError.new(
          "tool.execution_error",
          "#{error.class}: #{error.message}",
          {"tool" => JSON::Any.new(tool.name), "exception_type" => JSON::Any.new(error.class.to_s)},
        )
      end
      latency = (Time.instant - t0).total_seconds
      CachedToolResponse.new(
        output: result,
        error: nil,
        latency_seconds: latency,
        cost_usd: "0",
      )
    end
  end
end
