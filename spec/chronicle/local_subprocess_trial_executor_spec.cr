require "../spec_helper"
require "file_utils"

# Crystal source-pack ABI for the local trial executor. A candidate is always
# compiled from the pinned root's `entrypoint.cr`; it is never discovered from
# ambient load paths.
describe Chronicle::Sandbox::LocalSubprocessTrialExecutor do
  it "resolves the fixed pinned entrypoint" do
    executor = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new
    source = Chronicle::Sandbox::PackSource.new(root_dir: "/candidate")

    executor.entrypoint_path(source).should eq("/candidate/entrypoint.cr")
  end

  it "compiles a pinned source pack in a child and leaves the parent run unchanged" do
    root = pack_spec_dir("sandbox_child_#{Random::Secure.hex(4)}")
    File.write(File.join(root, "entrypoint.cr"), <<-CRYSTAL)
      module Chronicle::Sandbox::CandidatePack
        PACK = Chronicle::Pack.new(name: "trial_candidate", version: "0.1.0")
      end
      CRYSTAL
    File.write(File.join(root, "scenario.cr"), <<-CRYSTAL)
      module Chronicle::Sandbox::Scenario
        def self.run(rt)
          rt.graph.not_nil!.add_object("trial_note", %({"text":"child only"}))
        end
      end
      CRYSTAL

    db = File.join(Dir.tempdir, "chronicle-sandbox-#{Random::Secure.hex(4)}.db")
    store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    graph.add_object("parent_note", %({"text":"parent"}))
    at_event = store.iter_events.last.id
    bundle = Chronicle::Packs.compute_bundle_hash(root)
    specification = Chronicle::Sandbox::TrialSpecification.new(
      store_path: db, parent_run_id: "parent", at_event: at_event,
      pack_source: Chronicle::Sandbox::PackSource.new(root_dir: root, expected_bundle_hash: bundle, manifest_required: false),
      scenario: "scenario.cr",
    )

    result = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new.execute(specification.to_json)

    result.detail.should be_empty
    result.status.should eq("completed")
    result.budget_use.events_appended.should be > 0
    parent = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
    parent.iter_events.size.should eq(1)
    fork = Chronicle::SQLiteEventStore.new(db, run_id: result.event_log.run_id)
    fork.iter_events.any? { |event| event.type == "object.created" && event.payload.includes?("child only") }.should be_true
  end

  it "runs the child with a closed environment plus explicit passthrough" do
    root = pack_spec_dir("sandbox_environment_#{Random::Secure.hex(4)}")
    File.write(File.join(root, "entrypoint.cr"), <<-CRYSTAL)
      module Chronicle::Sandbox::CandidatePack
        PACK = Chronicle::Pack.new(name: "environment_candidate", version: "0.1.0")
      end
      CRYSTAL
    File.write(File.join(root, "scenario.cr"), <<-CRYSTAL)
      module Chronicle::Sandbox::Scenario
        def self.run(rt)
          raise "ambient secret leaked" if ENV["CHRONICLE_TRIAL_SECRET"]?
          raise "requested value missing" unless ENV["CHRONICLE_TRIAL_VISIBLE"]? == "visible"
        end
      end
      CRYSTAL

    ENV["CHRONICLE_TRIAL_SECRET"] = "hidden"
    ENV["CHRONICLE_TRIAL_VISIBLE"] = "visible"
    result = execute_trial(root, limits: Chronicle::Sandbox::TrialLimits.new(env_passthrough: ["CHRONICLE_TRIAL_VISIBLE"]))

    result.status.should eq("completed")
  ensure
    ENV.delete("CHRONICLE_TRIAL_SECRET")
    ENV.delete("CHRONICLE_TRIAL_VISIBLE")
  end

  it "terminates a trial that exceeds its parent-enforced wall-clock limit" do
    root = pack_spec_dir("sandbox_timeout_#{Random::Secure.hex(4)}")
    File.write(File.join(root, "entrypoint.cr"), <<-CRYSTAL)
      module Chronicle::Sandbox::CandidatePack
        PACK = Chronicle::Pack.new(name: "timeout_candidate", version: "0.1.0")
      end
      CRYSTAL
    File.write(File.join(root, "scenario.cr"), <<-CRYSTAL)
      module Chronicle::Sandbox::Scenario
        def self.run(rt)
          sleep 5
        end
      end
      CRYSTAL

    result = execute_trial(root, limits: Chronicle::Sandbox::TrialLimits.new(wall_clock_seconds: 1.0))

    result.status.should eq("limits_exceeded")
    result.detail.should contain("wall-clock")
  end

  it "preflights the local compiler and reports host-specific memory-cap degradation" do
    executor = Chronicle::Sandbox::LocalSubprocessTrialExecutor.new

    executor.preflight(Chronicle::Sandbox::TrialLimits.new).should be_empty
    executor.preflight(Chronicle::Sandbox::TrialLimits.new(max_rss_bytes: 1_024)).join.should contain("max_rss_bytes")
  end
end

private def execute_trial(
  root : String,
  limits : Chronicle::Sandbox::TrialLimits = Chronicle::Sandbox::TrialLimits.new,
) : Chronicle::Sandbox::TrialResult
  db = File.join(Dir.tempdir, "chronicle-sandbox-#{Random::Secure.hex(4)}.db")
  store = Chronicle::SQLiteEventStore.new(db, run_id: "parent")
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  graph.add_object("parent_note", %({"text":"parent"}))
  at_event = store.iter_events.last.id
  bundle = Chronicle::Packs.compute_bundle_hash(root)
  specification = Chronicle::Sandbox::TrialSpecification.new(
    store_path: db, parent_run_id: "parent", at_event: at_event,
    pack_source: Chronicle::Sandbox::PackSource.new(root_dir: root, expected_bundle_hash: bundle, manifest_required: false),
    scenario: "scenario.cr", limits: limits,
  )
  Chronicle::Sandbox::LocalSubprocessTrialExecutor.new.execute(specification.to_json)
end
