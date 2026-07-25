require "../spec_helper"

class MockModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

describe Clarity::LogAgent do
  it "constructs from a Crig::Agent" do
    crig_agent = Crig::Agent(MockModel).new(model: MockModel.new)
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent)
    log_agent.should be_a(Clarity::LogAgent(MockModel))
  end

  it "returns a CallModel step when started with a prompt" do
    crig_agent = Crig::Agent(MockModel).new(
      model: MockModel.new,
      preamble: "You are helpful.",
    )
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent)
    log_agent.start(Crig::Completion::Message.user("Hello"))

    step = log_agent.next_step
    step.call_model?.should be_true
    step.turn.should eq(1)
    step.prompt.should_not be_nil
  end

  it "builds an EffectRequest for a CallModel step" do
    crig_agent = Crig::Agent(MockModel).new(
      model: MockModel.new,
      preamble: "You are helpful.",
    )
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent)
    log_agent.start(Crig::Completion::Message.user("Hello"))
    step = log_agent.next_step

    effect = log_agent.model_effect(step)
    effect.should_not be_nil
    effect.as(Clarity::EffectRequest).kind.should eq(Clarity::EffectKind::Model)
    effect.as(Clarity::EffectRequest).payload.should contain("Hello")
  end

  it "produces tool EffectRequests after feeding a model response with tool calls" do
    crig_agent = Crig::Agent(MockModel).new(
      model: MockModel.new,
      preamble: "You are helpful.",
    )
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent)
    log_agent.start(Crig::Completion::Message.user("Use the web tool"))

    step = log_agent.next_step
    step.call_model?.should be_true

    # Simulate a model response that calls a tool
    choice = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
      Crig::Completion::AssistantContent.tool_call("tc_001", "web_search", JSON.parse(%({"q":"clarity"})))
    )
    turn = Crig::ModelTurn.new(
      message_id: "msg_001",
      choice: choice,
      usage: Crig::Completion::Usage.new(input_tokens: 10, output_tokens: 5),
      allowed_tools: ["web_search"],
    )

    log_agent.model_response(turn)

    call_tools_step = log_agent.next_step
    call_tools_step.call_tools?.should be_true
    call_tools_step.calls.should_not be_nil
    call_tools_step.calls.not_nil!.size.should eq(1)

    effects = log_agent.tool_effects(call_tools_step)
    effects.size.should eq(1)
    effects.first.kind.should eq(Clarity::EffectKind::Tool)
    effects.first.payload.should contain("web_search")
  end

  it "completes a full model→tools→done cycle" do
    crig_agent = Crig::Agent(MockModel).new(
      model: MockModel.new,
      preamble: "You are helpful.",
    )
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent)
    log_agent.start(Crig::Completion::Message.user("Research and report"))

    # Step 1: CallModel
    step1 = log_agent.next_step
    step1.call_model?.should be_true
    effect1 = log_agent.model_effect(step1)
    effect1.should_not be_nil

    # Model responds with a tool call
    choice1 = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
      Crig::Completion::AssistantContent.tool_call("tc_001", "search", JSON.parse(%({"q":"clarity"})))
    )
    turn1 = Crig::ModelTurn.new(
      message_id: "msg_001",
      choice: choice1,
      usage: Crig::Completion::Usage.new(input_tokens: 10, output_tokens: 5),
      allowed_tools: ["search"],
    )
    log_agent.model_response(turn1)

    # Step 2: CallTools
    step2 = log_agent.next_step
    step2.call_tools?.should be_true
    tool_effects = log_agent.tool_effects(step2)
    tool_effects.size.should eq(1)

    # Tool result comes back
    result_content = Crig::Completion::UserContent.tool_result(
      "tc_001",
      Crig::OneOrMany(Crig::Completion::ToolResultContent).one(
        Crig::Completion::ToolResultContent.text("found nothing")
      )
    )
    log_agent.tool_results([result_content])

    # Step 3: CallModel again with tool result context
    step3 = log_agent.next_step
    step3.call_model?.should be_true

    # Model responds with final text
    choice2 = Crig::OneOrMany(Crig::Completion::AssistantContent).one(
      Crig::Completion::AssistantContent.text("Nothing found.")
    )
    turn2 = Crig::ModelTurn.new(
      message_id: "msg_002",
      choice: choice2,
      usage: Crig::Completion::Usage.new(input_tokens: 15, output_tokens: 3),
      allowed_tools: [] of String,
    )
    log_agent.model_response(turn2)

    # Step 4: Done
    step4 = log_agent.next_step
    step4.done?.should be_true
    step4.response.should_not be_nil
    step4.response.not_nil!.output.should eq("Nothing found.")
  end
end
