require "./spec_helper"

describe Clarity do
  it "exposes its version" do
    Clarity::VERSION.should eq("0.1.0")
  end
end
