require "./spec_helper"

describe Chronicle do
  it "exposes its version" do
    Chronicle::VERSION.should eq("0.1.0")
  end
end
