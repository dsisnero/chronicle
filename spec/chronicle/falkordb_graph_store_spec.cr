require "../spec_helper"
require "./graph_store_conformance"
require "socket"

private def with_falkordb_reply(reply : String, &)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.as(Socket::IPAddress).port
  spawn do
    socket = server.accept
    socket << reply
    socket.flush
    socket.close
    server.close
  end
  yield "falkor://127.0.0.1:#{port}"
end

describe Chronicle::FalkorDBClient do
  it "decodes compact GRAPH.QUERY rows over RESP" do
    # [header, rows, statistics], where each row contains one scalar value.
    reply = "*3\r\n*0\r\n*2\r\n*1\r\n$5\r\nfirst\r\n*1\r\n:42\r\n$2\r\nok\r\n"
    with_falkordb_reply(reply) do |url|
      client = Chronicle::FalkorDBClient.new(url)
      rows = client.query("test_graph", "RETURN 1")
      rows.map { |row| row[0].text }.should eq(["first", "42"])
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
        backend = Chronicle::FalkorDBGraphStore.new(falkordb_url, graph_name: "chronicle_conformance")
        backend.clear
        backend
      end,
    )
  end
end
