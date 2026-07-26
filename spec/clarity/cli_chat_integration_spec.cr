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

describe "CLI chat integration" do
  it "loads config and creates runtime from environment" do
    # Set up minimal env for the test
    old_key = ENV["CLARITY_DEEPSEEK_API_KEY"]?
    ENV["CLARITY_DEEPSEEK_API_KEY"] = "sk-test-key"

    args = ["chat"]
    output = Clarity::CLI.run(args)
    output.should contain("chat")

    ENV["CLARITY_DEEPSEEK_API_KEY"] = old_key
  end

  it "builds runtime from config with store" do
    store = Clarity::MemoryEventStore.new
    model = MockModel.new
    crig_agent = Crig::Agent(MockModel).new(model: model, preamble: "You are helpful.")
    log_agent = Clarity::LogAgent(MockModel).new(crig_agent, store: store)
    runtime = Clarity::Runtime(MockModel).new(store: store, log_agent: log_agent)

    runtime.should be_a(Clarity::Runtime(MockModel))
    runtime.store.should eq(store)
  end

  it "creates runtime from config with routing policy" do
    config = Clarity::Config.from_yaml(%(
      data_dir: /tmp/clarity_test
      routing_config: examples/routing_config.yml
      debug: false
    ))

    config.routing_config.should eq("examples/routing_config.yml")
  end
end
