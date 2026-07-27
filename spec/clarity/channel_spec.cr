require "../spec_helper"

private class ChannelSpecModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Channel response")
      ),
      Crig::Completion::Usage.new,
      "raw",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    ["Channel response"]
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

private def channel_runtime
  store = Clarity::MemoryEventStore.new
  model = ChannelSpecModel.new
  agent = Crig::Agent(ChannelSpecModel).new(model: model, preamble: "You are helpful.")
  log_agent = Clarity::LogAgent(ChannelSpecModel).new(agent, store: store)
  {Clarity::Runtime(ChannelSpecModel).new(store: store, log_agent: log_agent), store}
end

describe "Channel command ingress" do
  it "records command provenance and a causal chat chain" do
    runtime, store = channel_runtime
    command = Clarity::Channel::SendMessage.new(
      command_id: "cmd_001", run_id: "run_001", content: "Hello", channel: "tui"
    )

    acknowledgement = runtime.handle(command)
    events = store.iter_events
    accepted = events.find! { |event| event.type == "command.accepted" }
    goal = events.find! { |event| event.type == "goal.created" }
    user_turn = events.find! do |event|
      event.type == "chat.message" && JSON.parse(event.payload).as_h["role"].as_s == "user"
    end

    acknowledgement.command_id.should eq("cmd_001")
    acknowledgement.event_id.should eq(accepted.id)
    acknowledgement.duplicate?.should be_false
    accepted.actor.should eq("channel.tui")
    JSON.parse(accepted.payload).as_h["command_id"].as_s.should eq("cmd_001")
    goal.caused_by.should eq(accepted.id)
    user_turn.caused_by.should eq(goal.id)
  end

  it "does not execute a duplicate command twice" do
    runtime, store = channel_runtime
    command = Clarity::Channel::SendMessage.new(
      command_id: "cmd_002", run_id: "run_001", content: "Hello", channel: "tui"
    )

    first = runtime.handle(command)
    event_count = store.count
    retry = runtime.handle(command)

    first.duplicate?.should be_false
    retry.duplicate?.should be_true
    retry.event_id.should eq(first.event_id)
    store.count.should eq(event_count)
  end
end
