require "../spec_helper"

describe Clarity::ApprovalAdapter do
  it "records approvals for capability-gated edge actions" do
    adapter = Clarity::ApprovalAdapter.new
    request = Clarity::ApprovalRequest.new("approval-1", Clarity::ApprovalKind::Shell, "git status")

    adapter.request(request)
    result = adapter.resolve(Clarity::ApprovalDecision.new(request.id, true))

    result.approved?.should be_true
    result.request.kind.should eq(Clarity::ApprovalKind::Shell)
  end

  it "rejects a decision for an unknown request" do
    adapter = Clarity::ApprovalAdapter.new

    expect_raises(Clarity::ApprovalError, "approval request not found") do
      adapter.resolve(Clarity::ApprovalDecision.new("missing", false))
    end
  end
end
