require "socket"
require "uri"

# FalkorDB is Redis-protocol compatible. Keeping the tiny RESP client here
# avoids a second client shard while preserving the adapter as an optional,
# server-backed GraphStore.
module Chronicle
  class FalkorDBResponse
    getter string : String?
    getter integer : Int64?
    getter array : Array(FalkorDBResponse)?

    def initialize(@string : String? = nil, @integer : Int64? = nil, @array : Array(FalkorDBResponse)? = nil)
    end

    def text : String
      @string || @integer.try(&.to_s) || raise "FalkorDB response is not scalar"
    end
  end

  class FalkorDBClient
    @socket : TCPSocket

    def initialize(url : String, username : String? = nil, password : String? = nil)
      endpoint = URI.parse(url)
      host = endpoint.host || raise ArgumentError.new("FalkorDB URL requires a host")
      @socket = TCPSocket.new(host, endpoint.port || 6379)
      if password
        username ? command(["AUTH", username, password]) : command(["AUTH", password])
      end
    end

    def query(graph_name : String, cypher : String) : Array(Array(FalkorDBResponse))
      table = command(["GRAPH.QUERY", graph_name, cypher, "--compact"]).array || [] of FalkorDBResponse
      return [] of Array(FalkorDBResponse) if table.size < 2

      (table[1].array || [] of FalkorDBResponse).map { |row| row.array || [] of FalkorDBResponse }
    end

    def close : Nil
      @socket.close
    end

    private def command(parts : Array(String)) : FalkorDBResponse
      @socket << "*#{parts.size}\r\n"
      parts.each { |part| @socket << "$#{part.bytesize}\r\n#{part}\r\n" }
      @socket.flush
      read_response
    end

    private def read_response : FalkorDBResponse
      case @socket.read_char
      when '+'
        FalkorDBResponse.new(string: read_line)
      when '-'
        raise "FalkorDB error: #{read_line}"
      when ':'
        FalkorDBResponse.new(integer: read_line.to_i64)
      when '$'
        size = read_line.to_i
        return FalkorDBResponse.new if size < 0

        bytes = Bytes.new(size)
        @socket.read_fully(bytes)
        @socket.read_char
        @socket.read_char
        FalkorDBResponse.new(string: String.new(bytes))
      when '*'
        size = read_line.to_i
        return FalkorDBResponse.new if size < 0

        values = Array(FalkorDBResponse).new(size) { read_response }
        FalkorDBResponse.new(array: values)
      else
        raise "unsupported FalkorDB RESP response"
      end
    end

    private def read_line : String
      line = @socket.gets('\n', chomp: true) || raise IO::EOFError.new
      line.rstrip('\r')
    end
  end

  # A FalkorDB-native GraphStore. Relations are native `:AGRelation` edges,
  # objects are `:AGNode:AGObject` nodes, and dangling endpoints are bare
  # `:AGNode` placeholders so projection cascade semantics are preserved.
  class FalkorDBGraphStore < GraphStore
    @client : FalkorDBClient
    @closed = false

    def initialize(url : String? = ENV["FALKORDB_URL"]?, @graph_name : String = "chronicle", username : String? = ENV["FALKORDB_USERNAME"]?, password : String? = ENV["FALKORDB_PASSWORD"]?)
      resolved_url = url || raise ArgumentError.new("set FALKORDB_URL or pass a FalkorDB URL")
      @client = FalkorDBClient.new(resolved_url, username, password)
      ensure_indexes
    end

    def put_object(obj : GraphObject) : Nil
      query("MERGE (o:AGNode {id: #{literal(obj.id)}}) SET o:AGObject, o.type = #{literal(obj.type)}, o.doc = #{literal(obj.to_json)}")
    end

    def get_object(object_id : String) : GraphObject?
      read_object(query("MATCH (o:AGObject {id: #{literal(object_id)}}) RETURN o.doc").first?)
    end

    def remove_object(object_id : String) : Nil
      query("MATCH (o:AGObject {id: #{literal(object_id)}}) REMOVE o:AGObject, o.type, o.doc WITH o OPTIONAL MATCH (o)-[e]-() WITH o, count(e) AS degree WHERE degree = 0 DELETE o")
    end

    def all_objects : Array(GraphObject)
      query("MATCH (o:AGObject) RETURN o.doc").compact_map { |row| read_object(row) }
    end

    def put_relation(rel : GraphRelation) : Nil
      remove_relation(rel.id)
      query("MERGE (s:AGNode {id: #{literal(rel.from_id)}}) MERGE (t:AGNode {id: #{literal(rel.to_id)}}) MERGE (s)-[r:AGRelation {id: #{literal(rel.id)}}}]->(t) SET r.type = #{literal(rel.type)}, r.doc = #{literal(rel.to_json)}")
    end

    def get_relation(relation_id : String) : GraphRelation?
      read_relation(query("MATCH ()-[r:AGRelation {id: #{literal(relation_id)}}]->() RETURN r.doc").first?)
    end

    def remove_relation(relation_id : String) : Nil
      query("MATCH (s)-[r:AGRelation {id: #{literal(relation_id)}}]->(t) DELETE r WITH [s, t] AS ends UNWIND ends AS n WITH DISTINCT n OPTIONAL MATCH (n)-[e]-() WITH n, count(e) AS degree WHERE degree = 0 AND NOT n:AGObject DELETE n")
    end

    def all_relations : Array(GraphRelation)
      query("MATCH ()-[r:AGRelation]->() RETURN r.doc").compact_map { |row| read_relation(row) }
    end

    def put_patch(patch : Patch) : Nil
      query("MERGE (p:AGPatch {id: #{literal(patch.id)}}) SET p.doc = #{literal(patch.to_json)}")
    end

    def get_patch(patch_id : String) : Patch?
      read_patch(query("MATCH (p:AGPatch {id: #{literal(patch_id)}}) RETURN p.doc").first?)
    end

    def all_patches : Array(Patch)
      query("MATCH (p:AGPatch) RETURN p.doc").compact_map { |row| read_patch(row) }
    end

    def remove_patch(patch_id : String) : Nil
      query("MATCH (p:AGPatch {id: #{literal(patch_id)}}) DELETE p")
    end

    def find_objects(type : String? = nil) : Array(GraphObject)
      cypher = "MATCH (o:AGObject)"
      cypher += " WHERE o.type = #{literal(type)}" if type
      query(cypher + " RETURN o.doc").compact_map { |row| read_object(row) }
    end

    def find_objects_in_types(types : Array(String)) : Array(GraphObject)
      return [] of GraphObject if types.empty?

      query("MATCH (o:AGObject) WHERE o.type IN [#{types.map { |type| literal(type) }.join(", ")}] RETURN o.doc").compact_map { |row| read_object(row) }
    end

    def find_relations(source : String? = nil, target : String? = nil, type : String? = nil) : Array(GraphRelation)
      clauses = [] of String
      clauses << "s.id = #{literal(source)}" if source
      clauses << "t.id = #{literal(target)}" if target
      clauses << "r.type = #{literal(type)}" if type
      cypher = "MATCH (s)-[r:AGRelation]->(t)"
      cypher += " WHERE #{clauses.join(" AND ")}" unless clauses.empty?
      query(cypher + " RETURN r.doc").compact_map { |row| read_relation(row) }
    end

    def neighborhood(object_id : String, depth : Int32 = 1) : {Array(GraphObject), Array(GraphRelation)}
      start = get_object(object_id)
      return {[] of GraphObject, [] of GraphRelation} if start.nil?
      return {[start], [] of GraphRelation} if depth < 1

      hops = depth.to_i
      objects = query("MATCH (start:AGObject {id: #{literal(object_id)}}) OPTIONAL MATCH (start)-[:AGRelation*1..#{hops}]-(o:AGObject) WITH start, collect(DISTINCT o) AS nodes UNWIND nodes + [start] AS node RETURN DISTINCT node.doc").compact_map { |row| read_object(row) }
      relations = query("MATCH path=(start:AGObject {id: #{literal(object_id)}})-[:AGRelation*1..#{hops}]-(node) UNWIND relationships(path) AS relation RETURN DISTINCT relation.doc").compact_map { |row| read_relation(row) }
      {objects, relations}
    end

    def match_chain(node_types : Array(String?), rels : Array({String, String})) : Array(ChainMatch)
      return [] of ChainMatch if node_types.empty?
      return find_objects(node_types[0]).map { |obj| ChainMatch.new(objects: [obj], relations: [] of GraphRelation) } if rels.empty?

      path = ["(n0:AGObject)"]
      conditions = [node_type_condition("n0", node_types[0])]
      rels.each_with_index do |(rel_type, direction), index|
        left = direction == "left" ? "<-" : "-"
        right = direction == "left" ? "-" : "->"
        path << "#{left}[r#{index}:AGRelation]#{right}(n#{index + 1}:AGObject)"
        conditions << "r#{index}.type = #{literal(rel_type)}"
        conditions << node_type_condition("n#{index + 1}", node_types[index + 1])
      end
      docs = (0...node_types.size).map { |index| "n#{index}.doc" } + (0...rels.size).map { |index| "r#{index}.doc" }
      query("MATCH #{path.join} WHERE #{conditions.compact.join(" AND ")} RETURN #{docs.join(", ")}").map do |row|
        objects = node_types.size.times.map { |index| GraphObject.from_json(row[index].text) }.to_a
        relations = rels.size.times.map { |index| GraphRelation.from_json(row[node_types.size + index].text) }.to_a
        ChainMatch.new(objects: objects, relations: relations)
      end
    end

    def clear : Nil
      query("MATCH (n) WHERE n:AGNode OR n:AGPatch DETACH DELETE n")
    end

    def close : Nil
      return if @closed
      @client.close
      @closed = true
    end

    private def ensure_indexes : Nil
      [
        "CREATE INDEX FOR (n:AGNode) ON (n.id)",
        "CREATE INDEX FOR (n:AGObject) ON (n.id)",
        "CREATE INDEX FOR ()-[r:AGRelation]->() ON (r.id)",
        "CREATE INDEX FOR ()-[r:AGRelation]->() ON (r.type)",
        "CREATE INDEX FOR (n:AGPatch) ON (n.id)",
      ].each { |statement| query(statement) rescue nil }
    end

    private def query(cypher : String) : Array(Array(FalkorDBResponse))
      @client.query(@graph_name, cypher)
    end

    private def literal(value : String) : String
      "'#{value.gsub("\\", "\\\\").gsub("'", "\\'")}'"
    end

    private def node_type_condition(node : String, type : String?) : String?
      type ? "#{node}.type = #{literal(type)}" : nil
    end

    private def read_object(row : Array(FalkorDBResponse)?) : GraphObject?
      row.try { |values| GraphObject.from_json(values[0].text) }
    end

    private def read_relation(row : Array(FalkorDBResponse)?) : GraphRelation?
      row.try { |values| GraphRelation.from_json(values[0].text) }
    end

    private def read_patch(row : Array(FalkorDBResponse)?) : Patch?
      row.try { |values| Patch.from_json(values[0].text) }
    end
  end
end
