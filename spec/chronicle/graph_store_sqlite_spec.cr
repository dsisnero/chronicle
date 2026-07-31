require "../spec_helper"
require "./graph_store_conformance"

# SQLite-backed GraphStore running the reusable conformance suite.
describe Chronicle::SQLiteGraphStore do
  paths = [] of String

  before_each do
    paths << File.tempname("clarity_gs", ".db")
  end

  after_each do
    paths.each { |p| File.delete(p) if File.exists?(p) }
    paths.clear
  end

  GraphStoreConformance.define_tests(Chronicle::SQLiteGraphStore.new(paths.last))
end
