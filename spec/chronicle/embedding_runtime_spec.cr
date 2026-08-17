require "../spec_helper"

# Runtime-owned embedding record/replay semantics (CONTRACT v1.8 #6). Ported
# from activegraph tests/test_embedding_replay.py: Runtime#embed records a
# content-keyed `embedding.requested`/`embedding.responded` pair (never the
# input text), serves recorded returns from the cache on load/fork with zero
# provider contact, records provider errors without caching, and strict replay
# rejects input-hash drift with `embedding_hash_mismatch`. `ctx.embed` threads
# the behavior + triggering event through the same recorded path.

require "file"
require "file_utils"

class EmbeddingTestProvider < Chronicle::EmbeddingProvider
  getter calls : Array({Array(String), String}) = [] of {Array(String), String}

  def default_model : String
    "test-embedding-v1"
  end

  def embed(texts : Array(String), model : String) : Array(Array(Float64))
    @calls << {texts, model}
    texts.map_with_index { |text, index| [text.size.to_f, index.to_f] }
  end
end

class NoContactEmbeddingProvider < Chronicle::EmbeddingProvider
  getter calls : Int32 = 0

  def default_model : String
    "test-embedding-v1"
  end

  def embed(texts : Array(String), model : String) : Array(Array(Float64))
    @calls += 1
    raise "strict replay contacted the embedding provider"
  end
end

class BadEmbeddingProvider < Chronicle::EmbeddingProvider
  def default_model : String
    "bad"
  end

  def embed(texts : Array(String), model : String) : Array(Array(Float64))
    [[1.0], [2.0]]
  end
end

module EmbeddingRuntimePack
  include Chronicle::Packs::DSL

  class_property captured : Array(Array(Float64))? = nil

  @[Behavior(name: "embedder", on: ["goal.created"])]
  def embedder(event : Chronicle::Event, graph : Chronicle::GraphProjection, ctx : Chronicle::Packs::BehaviorContext)
    goal = JSON.parse(event.payload)["goal"].as_s
    vectors = ctx.embed([goal])
    graph.add_object("embedding", JSON.build do |json|
      json.object { json.field "vector", vectors[0] }
    end)
    EmbeddingRuntimePack.captured = vectors
  end

  pack(name: "embedderpack", version: "0.1.0")
end

private def embedding_agent : Crig::Agent(PackModel)
  Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
end

private def embedding_mem_runtime(provider : Chronicle::EmbeddingProvider?, replay_cache : Bool = false)
  store = Chronicle::MemoryEventStore.new
  graph = Chronicle::GraphProjection.empty.attach_store(store)
  la = Chronicle::LogAgent(PackModel).new(embedding_agent, store: store, max_turns: 1)
  rt = Chronicle::Runtime(PackModel).new(
    store: store, log_agent: la, graph: graph,
    embedding_provider: provider,
    replay_embedding_cache: replay_cache,
    embedding_cache: replay_cache ? Chronicle::EmbeddingCache.new : nil,
  )
  {store, graph, rt}
end

private def embedding_db_path(tag : String) : String
  File.join(Dir.tempdir, "chronicle_embed_#{tag}_#{Random::Secure.hex(4)}.db")
end

describe Chronicle::Runtime do
  it "records a content-keyed requested/responded pair and harvests defensively" do
    _store, _graph, rt = embedding_mem_runtime(EmbeddingTestProvider.new)
    vectors = rt.embed(["alpha", "beta"])
    vectors.should eq([[5.0, 0.0], [4.0, 1.0]])

    events = rt.store.iter_events.to_a
    events.map(&.type).should eq(["embedding.requested", "embedding.responded"])
    request = events[0]
    response = events[1]
    request.payload.should_not contain("alpha")
    response.caused_by.should eq(request.id)
    JSON.parse(response.payload).as_h["vectors"].should eq(JSON.parse(%([[5.0,0.0],[4.0,1.0]])))

    cache = Chronicle::EmbeddingCache.from_events(events)
    inputs_hash = JSON.parse(request.payload).as_h["inputs_hash"].as_s
    cached = cache.get(inputs_hash).not_nil!
    cached.should eq([[5.0, 0.0], [4.0, 1.0]])
    cached[0][0] = 999.0
    cache.get(inputs_hash).should eq([[5.0, 0.0], [4.0, 1.0]])
  end

  it "requires a provider when model is omitted" do
    _store, _graph, rt = embedding_mem_runtime(nil)
    expect_raises(RuntimeError, /requires embedding_provider=/) { rt.embed(["alpha"]) }
  end

  it "records a provider error response without caching the malformed return" do
    _store, _graph, rt = embedding_mem_runtime(BadEmbeddingProvider.new)
    expect_raises(ArgumentError, /wrong vector count/) { rt.embed(["one"]) }

    request, response = rt.store.iter_events.to_a
    request.type.should eq("embedding.requested")
    response.type.should eq("embedding.responded")
    JSON.parse(response.payload).as_h["error"]["type"].as_s.should eq("ArgumentError")
    Chronicle::EmbeddingCache.from_events(rt.store.iter_events).size.should eq(0)
  end

  it "ctx.embed threads the behavior actor and triggering event through the recorded path" do
    EmbeddingRuntimePack.captured = nil
    store, _graph, rt = embedding_mem_runtime(EmbeddingTestProvider.new)
    rt.load_pack(EmbeddingRuntimePack::PACK)
    rt.run_goal("alpha")

    EmbeddingRuntimePack.captured.should eq([[5.0, 0.0]])
    req = store.iter_events.find! { |e| e.type == "embedding.requested" }
    req.actor.should eq("embedderpack.embedder")
    goal = store.iter_events.find! { |e| e.type == "goal.created" }
    req.caused_by.should eq(goal.id)
  end

  it "reuses the recorded return on load with zero provider contact" do
    db = embedding_db_path("load")
    provider = EmbeddingTestProvider.new
    store = Chronicle::SQLiteEventStore.new(db, run_id: "embed_parent")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    la = Chronicle::LogAgent(PackModel).new(embedding_agent, store: store, max_turns: 1)
    parent = Chronicle::Runtime(PackModel).new(
      store: store, log_agent: la, graph: graph, run_id: store.run_id,
      embedding_provider: provider,
    )
    expected = parent.embed(["alpha"], model: "test-embedding-v1")
    provider.calls.size.should eq(1)

    replay = NoContactEmbeddingProvider.new
    loaded = Chronicle::Runtime(PackModel).load(
      db, run_id: store.run_id, agent: embedding_agent,
      embedding_provider: replay, replay_embedding_cache: true,
    )
    loaded.embed(["alpha"], model: "test-embedding-v1").should eq(expected)
    replay.calls.should eq(0)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "a fork replays embeddings from the cache with zero provider contact" do
    db = embedding_db_path("fork")
    provider = EmbeddingTestProvider.new
    store = Chronicle::SQLiteEventStore.new(db, run_id: "embed_parent")
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    la = Chronicle::LogAgent(PackModel).new(embedding_agent, store: store, max_turns: 1)
    parent = Chronicle::Runtime(PackModel).new(
      store: store, log_agent: la, graph: graph, run_id: store.run_id,
      embedding_provider: provider,
    )
    parent.load_pack(EmbeddingRuntimePack::PACK)
    parent.run_goal("alpha")
    provider.calls.size.should eq(1)

    replay = NoContactEmbeddingProvider.new
    goal = store.iter_events.find! { |e| e.type == "goal.created" }
    fork = parent.fork(at_event: goal.id, embedding_provider: replay, replay_embedding_cache: true)
    fork.run_until_idle

    replay.calls.should eq(0)
    response = fork.store.iter_events.find! { |e| e.type == "embedding.responded" }
    JSON.parse(response.payload).as_h["cache_hit"].as_bool.should be_true
    obj = fork.graph.not_nil!.all_objects.find { |o| o.type == "embedding" }
    JSON.parse(obj.not_nil!.data)["vector"].as_a.should eq(JSON.parse(%([5.0,0.0])).as_a)
  ensure
    File.delete(db) if db && File.exists?(db)
  end

  it "strict replay rejects embedding input-hash drift with embedding_hash_mismatch" do
    store = Chronicle::MemoryEventStore.new
    agent = Crig::Agent(PackModel).new(model: PackModel.new, preamble: "")
    la = Chronicle::LogAgent(PackModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(PackModel).new(store: store, log_agent: la, embedding_provider: EmbeddingTestProvider.new)
    rt.embed(["alpha"], model: "test-embedding-v1")

    replay = NoContactEmbeddingProvider.new
    loaded = Chronicle::Runtime(PackModel).load(
      store, Chronicle::LogAgent(PackModel).new(embedding_agent, store: store),
      replay_strict: true, embedding_provider: replay,
    )
    error = expect_raises(Chronicle::ReplayDivergenceError) do
      loaded.embed(["changed"], model: "test-embedding-v1")
    end
    error.kind.should eq("embedding_hash_mismatch")
    replay.calls.should eq(0)
  end
end
