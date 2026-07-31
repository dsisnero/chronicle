require "../spec_helper"
require "./event_store_conformance"

# Conformance of the in-memory and SQLite backends against the reusable
# EventStore contract suite. Ported from activegraph tests/test_store_conformance.py.
describe Chronicle::MemoryEventStore do
  EventStoreConformance.define_tests(Chronicle::MemoryEventStore.new)
end

describe Chronicle::SQLiteEventStore do
  EventStoreConformance.define_tests(
    Chronicle::SQLiteEventStore.new(File.tempname("clarity_es", ".db"), "run_conformance"),
    cleanup = File.delete(store.db_path)
  )
end
