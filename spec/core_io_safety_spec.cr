require "./spec_helper"

describe "core I/O safety" do
  it "does not reference direct I/O, clocks, randomness, or process capabilities" do
    forbidden_references = [
      "File.",
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

    core_paths = Dir.glob("src/clarity/**/*.cr").reject do |path|
      path.ends_with?("platform_edge.cr")
    end

    core_paths.each do |path|
      source = File.read(path)
      forbidden_references.each do |reference|
        source.includes?(reference).should be_false, "#{path} references #{reference}"
      end
    end
  end
end
