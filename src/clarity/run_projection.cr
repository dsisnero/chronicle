require "json"

module Clarity
  # Pure derived state reconstructed by folding the ordered event log.
  struct RunProjection
    getter objective : String?

    def initialize(@objective : String?)
    end

    def self.empty : self
      new(nil)
    end

    def self.replay(events : Array(Event)) : self
      events.reduce(empty) do |projection, event|
        projection.apply(event)
      end
    end

    def apply(event : Event) : self
      return self unless event.type == "goal.created"

      payload = JSON.parse(event.payload).as_h
      self.class.new(payload["goal"].as_s)
    end
  end
end
