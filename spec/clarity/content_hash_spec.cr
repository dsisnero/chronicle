require "../spec_helper"

describe Clarity::ContentHash do
  it "returns the SHA-256 digest of canonical bytes" do
    Clarity::ContentHash.digest("hello").should eq(
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )
  end
end
