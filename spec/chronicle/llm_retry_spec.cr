require "../spec_helper"

describe Chronicle::RuntimeReason do
  describe ".transient_llm_reason?" do
    it "treats llm.network_error and llm.rate_limited as transient (CONTRACT v1.3 #3)" do
      Chronicle::RuntimeReason.transient_llm_reason?("llm.network_error").should be_true
      Chronicle::RuntimeReason.transient_llm_reason?("llm.rate_limited").should be_true
    end

    it "treats terminal reasons as non-transient" do
      Chronicle::RuntimeReason.transient_llm_reason?("llm.auth_error").should be_false
      Chronicle::RuntimeReason.transient_llm_reason?("llm.request_error").should be_false
    end
  end

  describe ".llm_retry_delay_seconds" do
    it "honors retry_after_seconds clamped to the maximum" do
      delay = Chronicle::RuntimeReason.llm_retry_delay_seconds(
        attempt_index: 0, initial: 1.0, maximum: 10.0,
        retry_after_seconds: 5.0,
      )
      delay.should eq(5.0)
    end

    it "returns 0 when initial delay is <= 0" do
      delay = Chronicle::RuntimeReason.llm_retry_delay_seconds(
        attempt_index: 3, initial: 0.0, maximum: 10.0,
      )
      delay.should eq(0.0)
    end

    it "computes exponential backoff capped at the maximum" do
      d0 = Chronicle::RuntimeReason.llm_retry_delay_seconds(attempt_index: 0, initial: 1.0, maximum: 10.0)
      d1 = Chronicle::RuntimeReason.llm_retry_delay_seconds(attempt_index: 1, initial: 1.0, maximum: 10.0)
      d2 = Chronicle::RuntimeReason.llm_retry_delay_seconds(attempt_index: 2, initial: 1.0, maximum: 10.0)
      d0.should eq(1.0)
      d1.should eq(2.0)
      d2.should eq(4.0)
    end

    it "caps at the maximum across many attempts" do
      delay = Chronicle::RuntimeReason.llm_retry_delay_seconds(attempt_index: 20, initial: 1.0, maximum: 10.0)
      delay.should eq(10.0)
    end

    it "ignores a malformed retry_after and falls back to backoff" do
      delay = Chronicle::RuntimeReason.llm_retry_delay_seconds(
        attempt_index: 1, initial: 1.0, maximum: 10.0,
        retry_after_seconds: -1.0,
      )
      delay.should eq(2.0)
    end
  end
end
