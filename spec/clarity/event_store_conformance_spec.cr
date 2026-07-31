require "../spec_helper"
require "./event_store_conformance"

# Conformance of the in-memory and SQLite backends against the reusable
# EventStore contract suite. Ported from activegraph tests/test_store_conformance.py.
describe Clarity::MemoryEventStore do
  EventStoreConformance.define_tests(Clarity::MemoryEventStore.new)
end

describe Clarity::SQLiteEventStore do
  EventStoreConformance.define_tests(
    Clarity::SQLiteEventStore.new(File.tempname("clarity_es", ".db"), "run_conformance"),
    cleanup = File.delete(store.db_path)
  )
end
