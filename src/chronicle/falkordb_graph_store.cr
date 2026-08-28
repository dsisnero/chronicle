require "socket"
require "uri"

# FalkorDB is Redis-protocol compatible. Keeping the tiny RESP client here
# avoids a second client shard while preserving the adapter as an optional,
# server-backed GraphStore.
module Chronicle
  alias FalkorDBQueryValue = String | Array(String) | Nil

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
      resolved_username = username || endpoint.user
      resolved_password = password || endpoint.password
      if resolved_password
        resolved_username ? command(["AUTH", resolved_username, resolved_password]) : command(["AUTH", resolved_password])
      end
    end

    # FalkorDB receives bound values as RESP command arguments after `params`.
    # The Cypher text contains only generated structure and `$name` references;
    # caller-controlled strings and lists are never interpolated into it.
    def query(graph_name : String, cypher : String, params : Hash(String, FalkorDBQueryValue) = {} of String => FalkorDBQueryValue) : Array(Array(FalkorDBResponse))
      parts = ["GRAPH.QUERY", graph_name, cypher, "--compact"]
      unless params.empty?
        parts << "params"
        parts << params.size.to_s
        params.each do |name, value|
          parts << name
          parts << parameter(value)
        end
      end
      table = command(parts).array || [] of FalkorDBResponse
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

    private def parameter(value : FalkorDBQueryValue) : String
      case value
      when String
        cypher_literal(value)
      when Array(String)
        "[#{value.map { |item| cypher_literal(item) }.join(", ")}]"
      when Nil
        "null"
      else
        raise ArgumentError.new("unsupported FalkorDB query parameter")
      end
    end

    private def cypher_literal(value : String) : String
      "'#{value.gsub("\\", "\\\\").gsub("'", "\\'")}'"
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
      query("MERGE (o:AGNode {id: $id}) SET o:AGObject, o.type = $type, o.doc = $doc", {"id" => obj.id, "type" => obj.type, "doc" => obj.to_json})
    end

    def get_object(object_id : String) : GraphObject?
      read_object(query("MATCH (o:AGObject {id: $id}) RETURN o.doc", {"id" => object_id}).first?)
    end

    def remove_object(object_id : String) : Nil
      query("MATCH (o:AGObject {id: $id}) REMOVE o:AGObject, o.type, o.doc WITH o OPTIONAL MATCH (o)-[e]-() WITH o, count(e) AS degree WHERE degree = 0 DELETE o", {"id" => object_id})
    end

    def all_objects : Array(GraphObject)
      query("MATCH (o:AGObject) RETURN o.doc").compact_map { |row| read_object(row) }
    end

    def put_relation(rel : GraphRelation) : Nil
      remove_relation(rel.id)
      query("MERGE (s:AGNode {id: $source}) MERGE (t:AGNode {id: $target}) MERGE (s)-[r:AGRelation {id: $id}]->(t) SET r.type = $type, r.doc = $doc", {"source" => rel.from_id, "target" => rel.to_id, "id" => rel.id, "type" => rel.type, "doc" => rel.to_json})
    end

    def get_relation(relation_id : String) : GraphRelation?
      read_relation(query("MATCH ()-[r:AGRelation {id: $id}]->() RETURN r.doc", {"id" => relation_id}).first?)
    end

    def remove_relation(relation_id : String) : Nil
      query("MATCH (s)-[r:AGRelation {id: $id}]->(t) DELETE r WITH [s, t] AS ends UNWIND ends AS n WITH DISTINCT n OPTIONAL MATCH (n)-[e]-() WITH n, count(e) AS degree WHERE degree = 0 AND NOT n:AGObject DELETE n", {"id" => relation_id})
    end

    def all_relations : Array(GraphRelation)
      query("MATCH ()-[r:AGRelation]->() RETURN r.doc").compact_map { |row| read_relation(row) }
    end

    def put_patch(patch : Patch) : Nil
      query("MERGE (p:AGPatch {id: $id}) SET p.doc = $doc", {"id" => patch.id, "doc" => patch.to_json})
    end

    def get_patch(patch_id : String) : Patch?
      read_patch(query("MATCH (p:AGPatch {id: $id}) RETURN p.doc", {"id" => patch_id}).first?)
    end

    def all_patches : Array(Patch)
      query("MATCH (p:AGPatch) RETURN p.doc").compact_map { |row| read_patch(row) }
    end

    def remove_patch(patch_id : String) : Nil
      query("MATCH (p:AGPatch {id: $id}) DELETE p", {"id" => patch_id})
    end

    def find_objects(type : String? = nil) : Array(GraphObject)
      query("MATCH (o:AGObject) WHERE $type IS NULL OR o.type = $type RETURN o.doc", {"type" => type}).compact_map { |row| read_object(row) }
    end

    def find_objects_in_types(types : Array(String)) : Array(GraphObject)
      return [] of GraphObject if types.empty?

      query("MATCH (o:AGObject) WHERE o.type IN $types RETURN o.doc", {"types" => types}).compact_map { |row| read_object(row) }
    end

    def find_relations(source : String? = nil, target : String? = nil, type : String? = nil) : Array(GraphRelation)
      query("MATCH (s)-[r:AGRelation]->(t) WHERE ($source IS NULL OR s.id = $source) AND ($target IS NULL OR t.id = $target) AND ($type IS NULL OR r.type = $type) RETURN r.doc", {"source" => source, "target" => target, "type" => type}).compact_map { |row| read_relation(row) }
    end

    def neighborhood(object_id : String, depth : Int32 = 1) : {Array(GraphObject), Array(GraphRelation)}
      start = get_object(object_id)
      return {[] of GraphObject, [] of GraphRelation} if start.nil?
      return {[start], [] of GraphRelation} if depth < 1

      hops = depth.to_i
      objects = query("MATCH (start:AGObject {id: $id}) OPTIONAL MATCH (start)-[:AGRelation*1..#{hops}]-(o:AGObject) WITH start, collect(DISTINCT o) AS nodes UNWIND nodes + [start] AS node RETURN DISTINCT node.doc", {"id" => object_id}).compact_map { |row| read_object(row) }
      relations = query("MATCH path=(start:AGObject {id: $id})-[:AGRelation*1..#{hops}]-(node) UNWIND relationships(path) AS relation RETURN DISTINCT relation.doc", {"id" => object_id}).compact_map { |row| read_relation(row) }
      {objects, relations}
    end

    def match_chain(node_types : Array(String?), rels : Array({String, String})) : Array(ChainMatch)
      return [] of ChainMatch if node_types.empty?
      return find_objects(node_types[0]).map { |obj| ChainMatch.new(objects: [obj], relations: [] of GraphRelation) } if rels.empty?

      path = ["(n0:AGObject)"]
      params = {"t0" => node_types[0]} of String => FalkorDBQueryValue
      conditions = ["($t0 IS NULL OR n0.type = $t0)"]
      rels.each_with_index do |(rel_type, direction), index|
        left = direction == "left" ? "<-" : "-"
        right = direction == "left" ? "-" : "->"
        path << "#{left}[r#{index}:AGRelation]#{right}(n#{index + 1}:AGObject)"
        params["rt#{index}"] = rel_type
        params["t#{index + 1}"] = node_types[index + 1]
        conditions << "($rt#{index} IS NULL OR r#{index}.type = $rt#{index})"
        conditions << "($t#{index + 1} IS NULL OR n#{index + 1}.type = $t#{index + 1})"
      end
      docs = (0...node_types.size).map { |index| "n#{index}.doc" } + (0...rels.size).map { |index| "r#{index}.doc" }
      query("MATCH #{path.join} WHERE #{conditions.join(" AND ")} RETURN #{docs.join(", ")}", params).map do |row|
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

    private def query(cypher : String, params : Hash(String, FalkorDBQueryValue) = {} of String => FalkorDBQueryValue) : Array(Array(FalkorDBResponse))
      @client.query(@graph_name, cypher, params)
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
