module Chronicle
  # Configuration for building a scoped View.
  # Ported from activegraph's behavior decorator view= spec.
  struct ViewSpec
    getter around : String?
    getter depth : Int32
    getter include_types : Array(String)?
    getter recent_events : Int32

    def initialize(
      @around : String? = nil,
      @depth : Int32 = 1,
      @include_types : Array(String)? = nil,
      @recent_events : Int32 = 50,
    )
    end
  end

  # Read-only scoped snapshot of the graph.
  # Ported from activegraph.core.view.View (CONTRACT #11).
  # Behaviors receive this as their view of the world; mutations go
  # through patches, not through view manipulation.
  struct View
    @objects : Array(GraphObject)
    @relations : Array(GraphRelation)
    @events : Array(Event)

    def initialize(
      @objects : Array(GraphObject) = [] of GraphObject,
      @relations : Array(GraphRelation) = [] of GraphRelation,
      @events : Array(Event) = [] of Event,
    )
    end

    # Objects in the view, optionally filtered by type.
    def objects(type : String? = nil) : Array(GraphObject)
      if type
        @objects.select { |obj| obj.type == type }
      else
        @objects
      end
    end

    # Relations in the view, optionally filtered by type.
    def relations(type : String? = nil) : Array(GraphRelation)
      if type
        @relations.select { |rel| rel.type == type }
      else
        @relations
      end
    end

    # Events in the view, optionally filtered by type.
    def events(type : String? = nil) : Array(Event)
      if type
        @events.select { |event| event.type == type }
      else
        @events
      end
    end
  end
end
