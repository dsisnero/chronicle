require "../spec_helper"

# LLM replay cache wiring specs. Ported from activegraph llm/cache.py +
# runtime replay_llm_cache/replay_strict (revision 8aedb1866cf5dce056af97529152ffd6f468a1ed).

class CacheMockModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    Crig::Completion::CompletionResponse(String).new(
      Crig::OneOrMany(Crig::Completion::AssistantContent).one(
        Crig::Completion::AssistantContent.text("Mock response")
      ),
      Crig::Completion::Usage.new(input_tokens: 5, output_tokens: 2),
      "raw",
      "msg_1",
    )
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "not implemented in test"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

class ExplodingModel
  include Crig::Completion::CompletionModel

  def completion(request : Crig::Completion::Request::CompletionRequest)
    raise "model must not be called during replay"
  end

  def stream(request : Crig::Completion::Request::CompletionRequest)
    raise "model must not be called during replay"
  end

  def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
    Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
  end
end

module LLMCacheWiringSpecHelper
  extend self

  def event(id : String, type : String, caused_by : String?, payload : String) : Chronicle::Event
    Chronicle::Event.new(
      schema_version: 1_u16, sequence: 1_u64, id: id,
      type: type, actor: "test", caused_by: caused_by,
      timestamp: Time.utc(2026, 1, 1, 0, 0, 0),
      payload: payload,
    )
  end
end

describe Chronicle::LLMCache do
  it "harvests llm.responded events keyed by the request hash" do
    requested = LLMCacheWiringSpecHelper.event("req_1", "llm.requested", nil, %({"request_hash":"abc","provider":"x","model":"y"}))
    responded = LLMCacheWiringSpecHelper.event("resp_1", "llm.responded", "req_1", %({"content":"hi","input_tokens":1,"output_tokens":2,"provider":"x","model":"y"}))
    cache = Chronicle::LLMCache.from_events([requested, responded])
    cache.has("abc").should be_true
    JSON.parse(cache.get("abc").not_nil!.payload)["content"].as_s.should eq("hi")
  end

  it "skips error-shaped llm.responded events" do
    requested = LLMCacheWiringSpecHelper.event("req_1", "llm.requested", nil, %({"request_hash":"abc"}))
    failed = LLMCacheWiringSpecHelper.event("resp_1", "llm.responded", "req_1", %({"error":"boom"}))
    cache = Chronicle::LLMCache.from_events([requested, failed])
    cache.size.should eq(0)
  end
end

describe Chronicle::Runtime do
  it "serves a cached response without calling the provider" do
    store1 = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(CacheMockModel).new(model: CacheMockModel.new)
    la = Chronicle::LogAgent(CacheMockModel).new(agent, store: store1)
    runtime = Chronicle::Runtime(CacheMockModel).new(store: store1, log_agent: la)
    first = runtime.run("Cache me")

    cache = Chronicle::LLMCache.from_events(store1.iter_events)
    cache.size.should be >= 1

    store2 = Chronicle::MemoryEventStore.new
    agent2 = Crig::Agent(ExplodingModel).new(model: ExplodingModel.new)
    la2 = Chronicle::LogAgent(ExplodingModel).new(agent2, store: store2)
    runtime2 = Chronicle::Runtime(ExplodingModel).new(store: store2, log_agent: la2, llm_cache: cache)
    second = runtime2.run("Cache me")

    second.should eq(first)
    store2.iter_events.any? { |e| e.type == "llm.responded" }.should be_true
  end

  it "records a cache_hit flag on served llm.requested events" do
    store1 = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(CacheMockModel).new(model: CacheMockModel.new)
    runtime = Chronicle::Runtime(CacheMockModel).new(store: store1, log_agent: Chronicle::LogAgent(CacheMockModel).new(agent, store: store1))
    runtime.run("Flag me")

    cache = Chronicle::LLMCache.from_events(store1.iter_events)
    store2 = Chronicle::MemoryEventStore.new
    agent2 = Crig::Agent(ExplodingModel).new(model: ExplodingModel.new)
    runtime2 = Chronicle::Runtime(ExplodingModel).new(store: store2, log_agent: Chronicle::LogAgent(ExplodingModel).new(agent2, store: store2), llm_cache: cache)
    runtime2.run("Flag me")

    served = store2.iter_events.find { |e| e.type == "llm.requested" }
    served.should_not be_nil
    JSON.parse(served.not_nil!.payload)["cache_hit"].as_bool.should be_true
  end

  it "populates the cache on Runtime.load with replay_llm_cache" do
    store = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(CacheMockModel).new(model: CacheMockModel.new)
    runtime = Chronicle::Runtime(CacheMockModel).new(store: store, log_agent: Chronicle::LogAgent(CacheMockModel).new(agent, store: store))
    runtime.run("Load cache")

    agent2 = Crig::Agent(ExplodingModel).new(model: ExplodingModel.new)
    loaded = Chronicle::Runtime(ExplodingModel).load(store, Chronicle::LogAgent(ExplodingModel).new(agent2, store: store), replay_llm_cache: true)
    loaded.run("Load cache").should_not be_empty
  end

  it "raises ReplayDivergenceError on strict prompt-hash mismatch" do
    store = Chronicle::MemoryEventStore.new
    store.append(LLMCacheWiringSpecHelper.event("req_1", "llm.requested", nil, %({"request_hash":"recorded_hash"})))
    agent = Crig::Agent(ExplodingModel).new(model: ExplodingModel.new)
    loaded = Chronicle::Runtime(ExplodingModel).load(store, Chronicle::LogAgent(ExplodingModel).new(agent, store: store), replay_strict: true)
    expect_raises(Chronicle::ReplayDivergenceError) do
      loaded.run("some prompt")
    end
  end
end
