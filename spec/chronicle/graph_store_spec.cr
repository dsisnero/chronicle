require "../spec_helper"
require "./graph_store_conformance"

# Conformance of the default backend against the reusable GraphStore contract
# suite. Ported from activegraph tests/test_graph_store.py.
describe Chronicle::InMemoryGraphStore do
  GraphStoreConformance.define_tests(Chronicle::InMemoryGraphStore.new)
end
