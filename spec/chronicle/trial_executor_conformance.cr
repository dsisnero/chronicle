require "../spec_helper"

# Reusable TrialExecutor adapter conformance suite. Ported from activegraph
# sandbox/conformance.py (CONTRACT v1.8 #12). A concrete executor gets full
# coverage by invoking `TrialExecutorConformance.define_tests` with two
# expressions: one producing a fresh executor adapter and one producing a
# valid serialized v1 specification.

module TrialExecutorConformance
  # `executor_factory` must yield a fresh Chronicle::Sandbox::TrialExecutor;
  # `specification_factory` must yield a valid version-1 serialized spec.
  macro define_tests(executor_factory, specification_factory)
    it "declares process and host isolation guarantees" do
      executor = {{executor_factory}}
      guarantees = executor.isolation_guarantees
      guarantees.process.should_not be_empty
      guarantees.filesystem.should_not be_empty
      guarantees.network.should_not be_empty
      guarantees.syscalls.should_not be_empty
      guarantees.environment.should_not be_empty
      guarantees.security_sandbox?.should be_a(Bool)
    end

    it "round-trips a serialized specification canonically" do
      serialized = {{specification_factory}}
      specification = Chronicle::Sandbox::TrialSpecification.from_json(serialized)
      Chronicle::Sandbox::TrialSpecification.from_json(specification.to_json).should eq(specification)
      specification.to_json.should eq(
        Chronicle::Sandbox::TrialSpecification.from_json(specification.to_json).to_json
      )
    end

    it "executes a complete provider-neutral result" do
      executor = {{executor_factory}}
      result = executor.execute({{specification_factory}})
      result.should be_a(Chronicle::Sandbox::TrialResult)
      Chronicle::Sandbox::TRIAL_OUTCOMES.should contain(result.status)
      result.budget_use.events_appended.should be >= 0
      result.budget_use.behavior_failures.should be >= 0
      result.event_log.store_path.should_not be_empty
      result.event_log.run_id.should_not be_empty
      result.isolation.should eq(executor.isolation_guarantees)
      if result.status == "completed"
        result.failure.should be_nil
      else
        failure = result.failure.not_nil!
        failure.kind.should eq(result.status)
      end
      report = result.to_report
      report.outcome.should eq(result.status)
      report.fork_run_id.should eq(result.event_log.run_id)
    end

    it "rejects a malformed specification before execution" do
      executor = {{executor_factory}}
      expect_raises(ArgumentError) do
        executor.execute("{}")
      end
    end
  end
end
