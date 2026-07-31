require "../spec_helper"

describe Chronicle::ApprovalAdapter do
  it "records approvals for capability-gated edge actions" do
    adapter = Chronicle::ApprovalAdapter.new
    request = Chronicle::ApprovalRequest.new("approval-1", Chronicle::ApprovalKind::Shell, "git status")

    adapter.request(request)
    result = adapter.resolve(Chronicle::ApprovalDecision.new(request.id, true))

    result.approved?.should be_true
    result.request.kind.should eq(Chronicle::ApprovalKind::Shell)
  end

  it "rejects a decision for an unknown request" do
    adapter = Chronicle::ApprovalAdapter.new

    expect_raises(Chronicle::ApprovalError, "approval request not found") do
      adapter.resolve(Chronicle::ApprovalDecision.new("missing", false))
    end
  end
end
