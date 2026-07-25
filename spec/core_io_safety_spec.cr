require "./spec_helper"

describe "core I/O safety" do
  it "does not reference direct I/O, clocks, randomness, or process capabilities" do
    forbidden_references = [
      "Dir.",
      "ENV[",
      "Process.",
      "Socket",
      "TCPSocket",
      "UDPSocket",
      "spawn",
      "Time.now",
      "Random",
      "UUID.random",
    ]

    # File.match? is a pure glob-pattern matcher (no filesystem I/O).
    exempt_file_usages = {"File.match?"}

    core_paths = Dir.glob("src/clarity/**/*.cr").reject do |path|
      path.ends_with?("platform_edge.cr") || path.ends_with?("routing_config.cr")
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
