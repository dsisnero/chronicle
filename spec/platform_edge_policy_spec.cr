require "./spec_helper"

describe "platform edge boundary" do
  it "confines CML references to the designated edge adapter" do
    core_paths = Dir.glob("src/chronicle/**/*.cr").reject do |path|
      path.ends_with?("platform_edge.cr")
    end

    core_paths.each do |path|
      File.read(path).includes?("CML::").should be_false, "#{path} references CML"
    end
    File.read("src/chronicle/platform_edge.cr").includes?("CML::").should be_true
  end
end
