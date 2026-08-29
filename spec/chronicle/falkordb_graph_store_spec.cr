require "../spec_helper"
require "./graph_store_conformance"
require "socket"

private def read_resp_command(socket : TCPSocket) : Array(String)
  count_line = socket.gets('\n', chomp: true) || raise IO::EOFError.new
  count_line[0].should eq('*')
  count = count_line[1..].to_i

  Array(String).new(count) do
    size_line = socket.gets('\n', chomp: true) || raise IO::EOFError.new
    size_line[0].should eq('$')
    bytes = Bytes.new(size_line[1..].to_i)
    socket.read_fully(bytes)
    socket.read_char
    socket.read_char
    String.new(bytes)
  end
end

private def with_falkordb_replies(replies : Array(String), &)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.as(Socket::IPAddress).port
  commands = Channel(Array(String)).new(replies.size)
  spawn do
    socket = server.accept
    replies.each do |reply|
      commands.send(read_resp_command(socket))
      socket << reply
      socket.flush
    end
    socket.close
    server.close
  end
  yield "falkor://127.0.0.1:#{port}", commands
end

private def with_falkordb_reply(reply : String, &)
  with_falkordb_replies([reply]) { |url, commands| yield url, commands }
end

describe Chronicle::FalkorDBClient do
  it "decodes compact GRAPH.QUERY rows over RESP" do
    # [header, rows, statistics], where each row contains one scalar value.
    reply = "*3\r\n*0\r\n*2\r\n*1\r\n$5\r\nfirst\r\n*1\r\n:42\r\n$2\r\nok\r\n"
    with_falkordb_reply(reply) do |url, _commands|
      client = Chronicle::FalkorDBClient.new(url)
      rows = client.query("test_graph", "RETURN 1")
      rows.map { |row| row[0].text }.should eq(["first", "42"])
      client.close
    end
  end

  it "encodes caller values in FalkorDB's CYPHER parameter prelude" do
    reply = "*3\r\n*0\r\n*0\r\n$2\r\nok\r\n"
    injected = "object' }) MATCH (n) DETACH DELETE n //"
    with_falkordb_reply(reply) do |url, commands|
      client = Chronicle::FalkorDBClient.new(url)
      client.query(
        "test_graph",
        "MATCH (o:AGObject {id: $id}) WHERE $type IS NULL OR o.type IN $types RETURN o.doc",
        {
          "id"    => injected,
          "type"  => nil,
          "types" => ["note", "a'b"],
        } of String => Chronicle::FalkorDBQueryValue,
      )

      commands.receive.should eq([
        "GRAPH.QUERY",
        "test_graph",
        "CYPHER id='object\\' }) MATCH (n) DETACH DELETE n //' type=null types=['note', 'a\\'b'] MATCH (o:AGObject {id: $id}) WHERE $type IS NULL OR o.type IN $types RETURN o.doc",
        "--compact",
      ])
      client.close
    end
  end

  it "uses credentials embedded in a FalkorDB URL" do
    query_reply = "*3\r\n*0\r\n*0\r\n$2\r\nok\r\n"
    with_falkordb_replies(["+OK\r\n", query_reply]) do |url, commands|
      client = Chronicle::FalkorDBClient.new(url.sub("falkor://", "falkor://chronicle:secret@"))
      client.query("test_graph", "RETURN 1")

      commands.receive.should eq(["AUTH", "chronicle", "secret"])
      commands.receive.should eq(["GRAPH.QUERY", "test_graph", "RETURN 1", "--compact"])
      client.close
    end
  end
end

# A real FalkorDB server is opt-in. Start one with the upstream image and set
# FALKORDB_URL=falkor://127.0.0.1:6379 before running this integration suite.
if falkordb_url = ENV["FALKORDB_URL"]?
  describe Chronicle::FalkorDBGraphStore do
    GraphStoreConformance.define_tests(
      begin
        graph_name = "chronicle_conformance_#{Process.pid}_#{Random::Secure.hex(4)}"
        backend = Chronicle::FalkorDBGraphStore.new(falkordb_url, graph_name: graph_name)
        backend.clear
        backend
      end,
    )
  end
end
