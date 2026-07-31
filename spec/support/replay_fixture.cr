module ReplayFixture
  extend self

  def events : Array(Chronicle::Event)
    goal = event(
      sequence: 1_u64,
      id: "evt_000001",
      type: "goal.created",
      payload: %({"goal":"verify replay without live effects"})
    )
    model_response = event(
      sequence: 2_u64,
      id: "evt_000002",
      type: "model.responded",
      caused_by: goal.id,
      payload: %({"request_hash":"abc123","response":"ready"})
    )
    tool_failure = event(
      sequence: 3_u64,
      id: "evt_000003",
      type: "tool.failed",
      caused_by: model_response.id,
      payload: %({"request_hash":"def456","error":"permission denied"})
    )

    [goal, model_response, tool_failure]
  end

  private def event(
    sequence : UInt64,
    id : String,
    type : String,
    payload : String,
    caused_by : String? = nil,
  ) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16,
      sequence: sequence,
      id: id,
      type: type,
      actor: "fixture",
      caused_by: caused_by,
      timestamp: Time.utc(2026, 7, 24, 12, 0, 0),
      payload: payload
    )
  end
end
