require "../spec_helper"

# The quickstart onboarding demo (upstream cli/quickstart.py run_fixture_mode):
# runs the diligence reference pack against a scripted provider (no API key,
# no network) and returns the rendered transcript lines. Chronicle's core is
# Sans-IO, so the transcript is returned as `Array(String)`; the CLI / caller
# writes it. The transcript shape (header, trace, memo, what-just-happened,
# try-next) mirrors the upstream quickstart session.

describe Chronicle::Quickstart do
  it "renders the fixture-mode quickstart transcript" do
    lines = Chronicle::Quickstart.fixture_mode_lines

    lines.first.should contain("quickstart")
    lines.any? { |line| line.includes?("pack:") && line.includes?("diligence") }.should be_true
    lines.any? { |line| line.includes?("companies:") && line.includes?("Northwind Robotics") }.should be_true
    lines.any? { |line| line.includes?("provider:") }.should be_true

    # Trace rendered from the run's event log.
    lines.any? { |line| line.includes?("[goal.created]") }.should be_true
    lines.any? { |line| line.includes?("[runtime.idle]") }.should be_true

    # The first memo rendered via the shared renderers.
    lines.any? { |line| line.includes?(" Memo: Northwind Robotics") }.should be_true
    lines.should contain("Summary:")
    lines.should contain("Open contradictions:")
    lines.should contain("Risks:")

    # Footer prose.
    lines.should contain(" What just happened")
    lines.should contain(" Try next")
  end
end
