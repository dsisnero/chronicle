require "./spec_helper"

describe "core I/O safety" do
  it "does not reference direct I/O or process capabilities" do
    forbidden_references = [
      "Dir.",
      "ENV[",
      "Process.",
      "Socket",
      "TCPSocket",
      "UDPSocket",
      "spawn",
    ]

    # File.match? is a pure glob-pattern matcher (no filesystem I/O).
    exempt_file_usages = {"File.match?"}

    # I/O boundary modules: these read/write filesystem or environment state
    # at the platform edge. The pack *loader* (packs/loader.cr) stays pure;
    # prompt loading, manifest parsing/hashing, and scaffolding touch disk.
    # Fixture-backed LLM providers (llm_recorded.cr) read/write fixture files
    # on the provider boundary; the pure hash/payload logic stays in
    # prompt.cr.
    io_boundary_paths = {
      "platform_edge.cr", "routing_config.cr", "cli.cr", "session_store.cr",
      "config.cr", "packs/prompt.cr", "packs/manifest.cr", "packs/scaffold.cr",
      "llm_recorded.cr",
    }

    core_paths = Dir.glob("src/chronicle/**/*.cr").reject do |path|
      io_boundary_paths.any? { |suffix| path.ends_with?(suffix) }
    end

    core_paths.each do |path|
      source = File.read(path)
      forbidden_references.each do |reference|
        source.includes?(reference).should be_false, "#{path} references #{reference}"
      end
      source.scan(/File\.\w+\??/) do |match|
        ref = match[0]
        unless exempt_file_usages.includes?(ref)
          fail("#{path} references forbidden I/O: #{ref}")
        end
      end
    end
  end
end
