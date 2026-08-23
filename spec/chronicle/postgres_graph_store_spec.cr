require "../spec_helper"
require "./graph_store_conformance"

# PostgreSQL-backed GraphStore running the reusable conformance suite. The
# namespace is cleared for each example so the shared disposable test database
# remains safe to reuse across focused and full-suite runs.
if postgres_url = ENV["CHRONICLE_POSTGRES_URL"]?
  describe Chronicle::PostgresGraphStore do
    GraphStoreConformance.define_tests(
      begin
        backend = Chronicle::PostgresGraphStore.new(postgres_url, namespace: "graph_store_conformance")
        backend.clear
        backend
      end,
    )

    it "isolates projections by namespace" do
      left = Chronicle::PostgresGraphStore.new(postgres_url, namespace: "graph_store_left")
      right = Chronicle::PostgresGraphStore.new(postgres_url, namespace: "graph_store_right")
      left.clear
      right.clear

      left.put_object(GraphStoreConformanceFixture.obj("shared_id"))
      right.get_object("shared_id").should be_nil
      left.get_object("shared_id").should_not be_nil
    end
  end
end
