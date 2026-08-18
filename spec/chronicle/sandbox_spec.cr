require "../spec_helper"

# Sandbox trial execution value types (upstream activegraph/sandbox/executor.py
# + __init__.py, CONTRACT v1.8 #9–#12): the provider-neutral trial
# specification, isolation guarantees, budget/artifact/event-log/failure
# references, and the structured trial result with the legacy report
# lift. Sans-IO — the value types are pure (serialization + validation); the
# subprocess executor / child runner stay at the platform edge.

describe Chronicle::Sandbox do
  describe "TrialIsolationGuarantees" do
    it "declares the local subprocess isolation posture" do
      isolation = Chronicle::Sandbox::LOCAL_SUBPROCESS_ISOLATION
      isolation.process.should eq("fresh_interpreter_subprocess")
      isolation.filesystem.should eq("shared_host_filesystem")
      isolation.network.should eq("unconfined")
      isolation.security_sandbox?.should be_false
      isolation.notes.should_not be_empty
    end
  end

  describe "TrialSpecification" do
    it "round-trips through canonical versioned JSON" do
      spec = Chronicle::Sandbox::TrialSpecification.new(
        store_path: "/tmp/run.db",
        parent_run_id: "parent",
        at_event: "goal_created_1",
        pack_source: Chronicle::Sandbox::PackSource.new(
          root_dir: "/packs/diligence",
          expected_bundle_hash: "sha256:abc",
          manifest_required: true,
        ),
        scenario: "diligence",
        limits: Chronicle::Sandbox::TrialLimits.new(max_events: 100, max_llm_calls: 0),
        label: "trial",
        extra_packs: [Chronicle::Sandbox::PackSource.new(root_dir: "/packs/extra")],
      )

      parsed = Chronicle::Sandbox::TrialSpecification.from_json(spec.to_json)
      parsed.store_path.should eq("/tmp/run.db")
      parsed.parent_run_id.should eq("parent")
      parsed.at_event.should eq("goal_created_1")
      parsed.pack_source.root_dir.should eq("/packs/diligence")
      parsed.pack_source.expected_bundle_hash.should eq("sha256:abc")
      parsed.pack_source.manifest_required?.should be_true
      parsed.scenario.should eq("diligence")
      parsed.limits.max_events.should eq(100)
      parsed.label.should eq("trial")
      parsed.extra_packs.size.should eq(1)
      parsed.extra_packs[0].root_dir.should eq("/packs/extra")
      parsed.schema_version.should eq(1)
    end

    it "rejects invalid JSON, wrong schema version, and missing fields" do
      expect_raises(ArgumentError, /valid JSON/) do
        Chronicle::Sandbox::TrialSpecification.from_json("{broken")
      end
      expect_raises(ArgumentError, /JSON object/) do
        Chronicle::Sandbox::TrialSpecification.from_json(%("a bare json string"))
      end
      expect_raises(ArgumentError, /schema_version/) do
        Chronicle::Sandbox::TrialSpecification.from_json(%({"schema_version":2}))
      end
      expect_raises(ArgumentError, /store_path/) do
        Chronicle::Sandbox::TrialSpecification.from_json(%({"schema_version":1,"parent_run_id":"p","at_event":"e","label":"l"}))
      end
    end
  end

  describe "TrialResult" do
    it "lifts a legacy TrialReport into the structured result and back" do
      report = Chronicle::Sandbox::TrialReport.new(
        outcome: "completed",
        fork_run_id: "fork_run",
        events_appended: 12,
        behavior_failures: 0,
        detail: "",
        exit_code: 0,
        warnings: ["memory cap degraded on this platform"],
      )
      spec = Chronicle::Sandbox::TrialSpecification.new(
        store_path: "/tmp/run.db",
        parent_run_id: "parent",
        at_event: "goal_created_1",
        pack_source: Chronicle::Sandbox::PackSource.new(root_dir: "/packs/diligence"),
        limits: Chronicle::Sandbox::TrialLimits.new,
        label: "trial",
      )

      result = Chronicle::Sandbox::TrialResult.from_report(
        report,
        specification: spec,
        isolation: Chronicle::Sandbox::LOCAL_SUBPROCESS_ISOLATION,
      )
      result.status.should eq("completed")
      result.failure.should be_nil
      result.budget_use.events_appended.should eq(12)
      result.budget_use.behavior_failures.should eq(0)
      result.event_log.run_id.should eq("fork_run")
      result.event_log.store_path.should eq("/tmp/run.db")
      result.warnings.should eq(["memory cap degraded on this platform"])

      lifted = result.to_report
      lifted.outcome.should eq("completed")
      lifted.fork_run_id.should eq("fork_run")
      lifted.events_appended.should eq(12)
      lifted.behavior_failures.should eq(0)
      lifted.exit_code.should eq(0)
      lifted.warnings.should eq(["memory cap degraded on this platform"])
    end

    it "records a failure when the report outcome is not completed" do
      report = Chronicle::Sandbox::TrialReport.new(
        outcome: "crashed",
        fork_run_id: "fork_run",
        events_appended: 3,
        behavior_failures: 1,
        detail: "segfault",
        exit_code: 139,
      )
      spec = Chronicle::Sandbox::TrialSpecification.new(
        store_path: "/tmp/run.db",
        parent_run_id: "parent",
        at_event: "goal_created_1",
        pack_source: Chronicle::Sandbox::PackSource.new(root_dir: "/packs/diligence"),
        label: "trial",
      )

      result = Chronicle::Sandbox::TrialResult.from_report(
        report,
        specification: spec,
        isolation: Chronicle::Sandbox::LOCAL_SUBPROCESS_ISOLATION,
      )
      failure = result.failure.not_nil!
      failure.kind.should eq("crashed")
      failure.message.should eq("segfault")
      failure.exit_code.should eq(139)
    end
  end
end
