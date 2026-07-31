require "../spec_helper"

private alias PM = Chronicle::Routing::PermissionMode

describe Chronicle::ToolPermission do
  it "allows a tool with allow permission" do
    permissions = {"file_read" => PM::Allow, "shell" => PM::Deny}
    result = Chronicle::ToolPermission.check("file_read", permissions)
    result.should eq(Chronicle::ToolPermission::Result::Allow)
  end

  it "denies a tool with deny permission" do
    permissions = {"file_read" => PM::Allow, "shell" => PM::Deny}
    result = Chronicle::ToolPermission.check("shell", permissions)
    result.should eq(Chronicle::ToolPermission::Result::Deny)
  end

  it "returns ask for tools with ask permission" do
    permissions = {"network" => PM::Ask}
    result = Chronicle::ToolPermission.check("network", permissions)
    result.should eq(Chronicle::ToolPermission::Result::Ask)
  end

  it "defaults to deny for unknown tools" do
    permissions = {"file_read" => PM::Allow}
    result = Chronicle::ToolPermission.check("unknown_tool", permissions)
    result.should eq(Chronicle::ToolPermission::Result::Deny)
  end

  it "approves an ask tool" do
    result = Chronicle::ToolPermission::Check.new
    result.request("network")
    result.approve("network")
    result.approved?("network").should be_true
  end

  it "rejects an ask tool" do
    result = Chronicle::ToolPermission::Check.new
    result.request("network")
    result.reject("network")
    result.approved?("network").should be_false
  end
end
