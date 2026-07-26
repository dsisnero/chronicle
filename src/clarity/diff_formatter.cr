require "similar"

module Clarity
  # Formats structural diffs between graph projections as human-readable text.
  module DiffFormatter
    extend self

    def format(diff : GraphDiff) : String
      io = IO::Memory.new
      format(diff, io)
      io.to_s
    end

    def format(diff : GraphDiff, io : IO) : Nil
      added_objs = diff.added_object_ids
      removed_objs = diff.removed_object_ids
      added_rels = diff.added_relation_ids
      removed_rels = diff.removed_relation_ids

      if added_objs.empty? && removed_objs.empty? && added_rels.empty? && removed_rels.empty?
        io.puts "no changes"
        return
      end

      unless added_objs.empty?
        io.puts "added objects:"
        added_objs.each { |id| io.puts "  + #{id}" }
      end

      unless removed_objs.empty?
        io.puts "removed objects:"
        removed_objs.each { |id| io.puts "  - #{id}" }
      end

      unless added_rels.empty?
        io.puts "added relations:"
        added_rels.each { |id| io.puts "  + #{id}" }
      end

      unless removed_rels.empty?
        io.puts "removed relations:"
        removed_rels.each { |id| io.puts "  - #{id}" }
      end
    end
  end
end
