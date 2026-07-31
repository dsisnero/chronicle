require "json"

# Shared JSON value comparison for the deterministic core. Mirrors Python's
# operator semantics as used by the pattern matcher (patterns.cr) and the
# `objects(where:)` predicate (graph_projection.cr).
module Chronicle
  module JsonCompare
    extend self

    # Numeric-aware equality: 3 == 3.0 is true, like Python.
    def json_equal?(a : JSON::Any, b : JSON::Any) : Bool
      ra = a.raw
      rb = b.raw
      if ra.is_a?(Int64) && rb.is_a?(Int64)
        ra == rb
      elsif ra.is_a?(Float64) && rb.is_a?(Float64)
        ra == rb
      elsif ra.is_a?(Int64) && rb.is_a?(Float64)
        ra.to_f64 == rb
      elsif ra.is_a?(Float64) && rb.is_a?(Int64)
        ra == rb.to_f64
      else
        ra == rb
      end
    end

    # Three-state ordered comparison. Returns nil when either operand is null
    # (no match, mirroring Python's `a is not None` guard) and raises
    # PatternTypeError for incomparable non-nil types (mirroring Python's
    # TypeError).
    def compare_json(op : String, a : JSON::Any, b : JSON::Any) : Int32?
      return nil if a.raw.nil? || b.raw.nil?
      case {a.raw, b.raw}
      when {Int64, Int64}
        a.raw.as(Int64) <=> b.raw.as(Int64)
      when {Float64, Float64}
        a.raw.as(Float64) <=> b.raw.as(Float64)
      when {Int64, Float64}
        a.raw.as(Int64).to_f64 <=> b.raw.as(Float64)
      when {Float64, Int64}
        a.raw.as(Float64) <=> b.raw.as(Int64).to_f64
      when {String, String}
        a.raw.as(String) <=> b.raw.as(String)
      when {Bool, Bool}
        (a.raw.as(Bool) ? 1 : 0) <=> (b.raw.as(Bool) ? 1 : 0)
      else
        raise PatternTypeError.new(
          "'#{op}' not supported between instances of " \
          "'#{a.raw.class}' and '#{b.raw.class}'"
        )
      end
    end

    def ordered?(op : String, a : JSON::Any, b : JSON::Any, & : Int32 -> Bool) : Bool
      cmp = compare_json(op, a, b)
      cmp.nil? ? false : yield cmp
    end

    # Membership: is `a` equal to any element of the array `b`?
    def in?(a : JSON::Any, b : JSON::Any) : Bool
      array = b.raw.as?(Array(JSON::Any))
      return false if array.nil?
      array.any? { |element| json_equal?(a, element) }
    end

    # Parse an object's stored JSON data string into a hash of values.
    def object_data_hash(data : String) : Hash(String, JSON::Any)
      h = JSON.parse(data).as_h?
      h || {} of String => JSON::Any
    rescue JSON::ParseException
      {} of String => JSON::Any
    end
  end
end
