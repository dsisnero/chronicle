require "../spec_helper"
require "./event_store_conformance"

# The database URL is deliberately opt-in so normal unit-test users do not
# need a local server. CI and the parity gate set it to a disposable database.
if postgres_url = ENV["CHRONICLE_POSTGRES_URL"]?
  describe Chronicle::PostgresEventStore do
    EventStoreConformance.define_tests(
      Chronicle::PostgresEventStore.new(postgres_url, run_id: "run_conformance_#{Random::Secure.hex(4)}"),
    )

    it "forks a run transactionally with copied event history" do
      parent = Chronicle::PostgresEventStore.new(postgres_url, run_id: "parent_#{Random::Secure.hex(4)}")
      parent.append(EventStoreConformanceFixture.event("fork_1"))
      parent.append(EventStoreConformanceFixture.event("fork_2"))

      Chronicle::PostgresEventStore.fork_run(
        postgres_url, parent_run_id: parent.run_id, new_run_id: "child_#{Random::Secure.hex(4)}",
        at_event_id: "fork_1", label: "trial", created_at: Time.utc.to_rfc3339,
      ).should eq(1)
    ensure
      parent.close if parent
    end

    it "preserves run lineage metadata and selects the latest active run" do
      parent_id = "metadata_parent_#{Random::Secure.hex(4)}"
      child_id = "metadata_child_#{Random::Secure.hex(4)}"
      parent = Chronicle::PostgresEventStore.new(postgres_url, run_id: parent_id)
      parent.upsert_run(created_at: Time.utc.to_rfc3339, label: "parent", goal: "goal")
      parent.append(EventStoreConformanceFixture.event("metadata_event"))
      Chronicle::PostgresEventStore.fork_run(
        postgres_url, parent_run_id: parent_id, new_run_id: child_id,
        at_event_id: "metadata_event", label: "child", created_at: Time.utc.to_rfc3339,
      ).should eq(1)

      child = Chronicle::PostgresEventStore.new(postgres_url, run_id: child_id)
      record = child.get_run.not_nil!
      record.parent_run_id.should eq(parent_id)
      record.forked_at_event_id.should eq("metadata_event")
      record.label.should eq("child")
      Chronicle::PostgresEventStore.list_runs(postgres_url).map(&.run_id).should contain(child_id)
      Chronicle::PostgresEventStore.most_recent_run_id(postgres_url).should_not be_nil
    ensure
      parent.close if parent
      child.close if child
    end
  end
end
