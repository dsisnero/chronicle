require "opentelemetry-sdk"

module Chronicle
  # OpenTelemetry-backed Metrics adapter. The caller owns the meter and any
  # exporter lifecycle; this adapter only creates and observes instruments.
  class OpenTelemetryMetrics < Metrics
    @counters = {} of String => OpenTelemetry::Instrument::Counter
    @histograms = {} of String => OpenTelemetry::Instrument::Histogram
    @gauges = {} of String => OpenTelemetry::Instrument::UpDownCounter
    @gauge_values = {} of String => Float64
    @creation_locks = {} of String => Mutex
    @lock = Mutex.new

    def initialize(@meter : OpenTelemetry::Meter)
    end

    def counter(name : String, tags : Hash(String, String), value : Float64 = 1.0) : Nil
      instrument = counter_for(name, tags)
      instrument.add(value, attributes(tags))
    end

    def histogram(name : String, tags : Hash(String, String), value : Float64) : Nil
      instrument = histogram_for(name, tags)
      instrument.record(value, attributes(tags))
    end

    def gauge(name : String, tags : Hash(String, String), value : Float64) : Nil
      instrument = gauge_for(name, tags)
      value_key = "#{instrument_key(name, tags)}=#{tags.keys.sort.map { |key| tags[key] }.join("\u001f")}"
      delta = @lock.synchronize do
        previous = @gauge_values[value_key]? || 0.0
        @gauge_values[value_key] = value
        value - previous
      end
      instrument.add(delta, attributes(tags)) unless delta == 0.0
    end

    private def counter_for(name, tags)
      key = instrument_key(name, tags)
      creation_lock(key).synchronize do
        @lock.synchronize { @counters[key]? } || begin
          created = @meter.create_counter(name, description: name.gsub('_', ' '))
          @lock.synchronize { @counters[key] ||= created }
        end
      end
    end

    private def histogram_for(name, tags)
      key = instrument_key(name, tags)
      creation_lock(key).synchronize do
        @lock.synchronize { @histograms[key]? } || begin
          created = @meter.create_histogram(name, description: name.gsub('_', ' '))
          @lock.synchronize { @histograms[key] ||= created }
        end
      end
    end

    private def gauge_for(name, tags)
      key = instrument_key(name, tags)
      creation_lock(key).synchronize do
        @lock.synchronize { @gauges[key]? } || begin
          created = @meter.create_up_down_counter(name, description: name.gsub('_', ' '))
          @lock.synchronize { @gauges[key] ||= created }
        end
      end
    end

    private def instrument_key(name : String, tags : Hash(String, String)) : String
      "#{name}\u001e#{tags.keys.sort.join("\u001f")}"
    end

    private def creation_lock(key : String) : Mutex
      @lock.synchronize { @creation_locks[key] ||= Mutex.new }
    end

    private def attributes(tags : Hash(String, String)) : Hash(String, OpenTelemetry::ValueTypes)
      values = {} of String => OpenTelemetry::ValueTypes
      tags.each { |key, value| values[key] = value }
      values
    end
  end
end
