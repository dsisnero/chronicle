require "../spec_helper"
require "./trial_executor_conformance"

# TrialExecutor protocol + RecordingTrialExecutor test double + TRIAL_OUTCOMES
# (upstream activegraph/sandbox/executor.py + __init__.py, CONTRACT v1.8
# #9–#12). Sans-IO: the protocol and the recording double are pure — only the
# LocalSubprocessTrialExecutor / _child runner stay at the platform edge.

module TrialExecutorFixture
  extend self

  def isolation : Chronicle::Sandbox::TrialIsolationGuarantees
    Chronicle::Sandbox::TrialIsolationGuarantees.new(
      process: "none", filesystem: "none", network: "none",
      syscalls: "none", environment: "none", security_sandbox: false,
    )
  end

  def recorded_result : Chronicle::Sandbox::TrialResult
    Chronicle::Sandbox::TrialResult.new(
      status: "scenario_failed",
      budget_use: Chronicle::Sandbox::TrialBudgetUse.new(3, 1, Chronicle::Sandbox::TrialLimits.new(max_events: 10)),
      artifacts: [Chronicle::Sandbox::TrialArtifactReference.new(
        name: "summary", uri: "memory://summary", media_type: "text/plain",
      )],
      event_log: Chronicle::Sandbox::TrialEventLogReference.new("record.db", "run_recorded"),
      failure: Chronicle::Sandbox::TrialFailureDetails.new("scenario_failed", "fixture failure", 30),
      isolation: isolation,
      detail: "fixture failure",
      exit_code: 30,
    )
  end

  def specification : Chronicle::Sandbox::TrialSpecification
    Chronicle::Sandbox::TrialSpecification.new(
      store_path: "record.db",
      parent_run_id: "run_parent",
      at_event: "evt_001",
      pack_source: Chronicle::Sandbox::PackSource.new(
        root_dir: "/pinned/pack",
        expected_bundle_hash: "sha256:#{"a" * 64}",
      ),
    )
  end

  # A fresh recording executor pre-loaded with one valid result, so it can
  # answer the conformance suite's execute call.
  def executor : Chronicle::Sandbox::RecordingTrialExecutor
    Chronicle::Sandbox::RecordingTrialExecutor.new(
      [recorded_result],
      isolation_guarantees: isolation,
    )
  end
end

describe Chronicle::Sandbox do
  describe "TRIAL_OUTCOMES" do
    it "is the closed five-outcome set" do
      Chronicle::Sandbox::TRIAL_OUTCOMES.should eq([
        "completed",
        "scenario_failed",
        "limits_exceeded",
        "materialization_failed",
        "crashed",
      ])
    end
  end

  describe "TrialExecutor protocol" do
    it "exposes isolation_guarantees and execute on a conforming adapter" do
      executor = TrialExecutorFixture.executor
      executor.should be_a(Chronicle::Sandbox::TrialExecutor)
    end
  end

  describe "RecordingTrialExecutor" do
    it "records parsed specs and returns fixtures in order" do
      isolation = TrialExecutorFixture.isolation
      fixture = TrialExecutorFixture.recorded_result
      executor = Chronicle::Sandbox::RecordingTrialExecutor.new([fixture], isolation_guarantees: isolation)
      specification = TrialExecutorFixture.specification

      returned = executor.execute(specification.to_json)
      returned.status.should eq("scenario_failed")
      returned.event_log.run_id.should eq("run_recorded")
      returned.failure.not_nil!.message.should eq("fixture failure")
      returned.isolation.should eq(isolation)
      executor.specifications.should eq([specification])
      executor.serialized_specifications.should eq([specification.to_json])

      expect_raises(RuntimeError, /no result remaining/) do
        executor.execute(specification.to_json)
      end
    end

    it "declares the none-test-double isolation posture when unset" do
      executor = Chronicle::Sandbox::RecordingTrialExecutor.new([] of Chronicle::Sandbox::TrialResult)
      guarantees = executor.isolation_guarantees
      guarantees.process.should eq("none_test_double")
      guarantees.filesystem.should eq("none")
      guarantees.network.should eq("none")
      guarantees.syscalls.should eq("none")
      guarantees.environment.should eq("none")
      guarantees.security_sandbox?.should be_false
    end

    it "rejects a malformed specification before recording" do
      executor = Chronicle::Sandbox::RecordingTrialExecutor.new([] of Chronicle::Sandbox::TrialResult)
      expect_raises(ArgumentError) do
        executor.execute("{}")
      end
      executor.specifications.should be_empty
    end
  end

  describe "TrialExecutorConformance" do
    TrialExecutorConformance.define_tests(
      TrialExecutorFixture.executor,
      TrialExecutorFixture.specification.to_json
    )
  end
end
