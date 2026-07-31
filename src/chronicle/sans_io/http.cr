module Chronicle
  module SansIO
    class HttpProtocolError < Exception
    end

    struct HttpLimits
      getter max_header_bytes : Int32
      getter max_incomplete_bytes : Int32

      def initialize(@max_header_bytes : Int32 = 64 * 1024, @max_incomplete_bytes : Int32 = 1024 * 1024)
        raise ArgumentError.new("max_header_bytes must be positive") unless @max_header_bytes > 0
        raise ArgumentError.new("max_incomplete_bytes must be positive") unless @max_incomplete_bytes > 0
      end
    end

    enum HttpRole
      Client
      Server
    end

    module HttpConnectionPolicy
      extend self

      # h11-compatible HTTP/1 persistence policy. HTTP/1.0 is deliberately
      # close-by-default; HTTP/1.1 remains persistent unless a Connection
      # header contains the case-insensitive `close` token.
      def keep_alive?(http_version : String, headers : Hash(String, String)) : Bool
        return false unless http_version == "HTTP/1.1"

        !connection_tokens(headers).includes?("close")
      end

      private def connection_tokens(headers : Hash(String, String)) : Array(String)
        headers.each_with_object([] of String) do |(name, value), tokens|
          next unless name.downcase == "connection"
          value.split(',').each { |token| tokens << token.strip.downcase }
        end
      end
    end

    struct HttpRequest
      getter method : String
      getter path : String
      getter headers : Hash(String, String)
      getter body : String
      getter trailers : Hash(String, String)
      getter http_version : String

      def initialize(
        @method : String,
        @path : String,
        @headers : Hash(String, String),
        @body : String,
        @trailers : Hash(String, String) = {} of String => String,
        @http_version : String = "HTTP/1.1",
      )
      end
    end

    struct HttpResponse
      getter status : Int32
      getter reason : String
      getter headers : Hash(String, String)
      getter body : String
      getter trailers : Hash(String, String)
      getter http_version : String

      def initialize(
        @status : Int32,
        @reason : String,
        @headers : Hash(String, String),
        @body : String,
        @trailers : Hash(String, String) = {} of String => String,
        @http_version : String = "HTTP/1.1",
      )
      end
    end

    # Incremental HTTP request framing without sockets or other system
    # capabilities. The complete HTTP/1 connection state machine is delivered
    # separately; this adapter preserves complete inbound request boundaries.
    class HttpParser
      @buffer = ""

      def finish : Array(HttpRequest)
        raise HttpProtocolError.new("unexpected EOF in HTTP request") unless @buffer.empty?

        [] of HttpRequest
      end

      def feed(chunk : String) : Array(HttpRequest)
        @buffer += chunk
        requests = [] of HttpRequest
        while request = next_request
          requests << request
        end
        requests
      end

      private def next_request : HttpRequest?
        header_end = @buffer.index("\r\n\r\n")
        return nil unless header_end

        method, path, version, headers, header_values = parse_request_head(header_end)
        next_body_request(method, path, version, headers, header_values, header_end + 4)
      end

      private def parse_request_head(header_end : Int32) : Tuple(String, String, String, Hash(String, String), Hash(String, Array(String)))
        header_block = @buffer.byte_slice(0, header_end) || ""
        lines = header_block.split("\r\n")
        method, path, version = parse_request_line(lines.shift? || raise HttpProtocolError.new("missing request line"))
        headers, header_values = parse_headers(lines)
        {method, path, version, headers, header_values}
      end

      private def parse_request_line(line : String) : Tuple(String, String, String)
        method, path, version = line.split(" ", 3)
        if method && path && (version == "HTTP/1.0" || version == "HTTP/1.1")
          {method, path, version}
        else
          raise HttpProtocolError.new("invalid HTTP request line")
        end
      end

      private def next_body_request(
        method : String,
        path : String,
        version : String,
        headers : Hash(String, String),
        header_values : Hash(String, Array(String)),
        body_start : Int32,
      ) : HttpRequest?
        content_lengths = header_values["content-length"]? || [] of String
        transfer_encodings = header_values["transfer-encoding"]? || [] of String
        validate_framing!(content_lengths, transfer_encodings)
        return next_chunked_request(method, path, version, headers, body_start) unless transfer_encodings.empty?

        content_length = parse_content_length(content_lengths)
        total_length = body_start + content_length
        return nil if @buffer.bytesize < total_length

        body = @buffer.byte_slice(body_start, content_length) || ""
        consume(total_length)
        HttpRequest.new(method, path, headers, body, http_version: version)
      end

      private def validate_framing!(content_lengths : Array(String), transfer_encodings : Array(String)) : Nil
        if !content_lengths.empty? && !transfer_encodings.empty?
          raise HttpProtocolError.new("request has both Transfer-Encoding and Content-Length")
        end
        return if transfer_encodings.empty?
        return if transfer_encodings.size == 1 && transfer_encodings.first.downcase == "chunked"

        raise HttpProtocolError.new("unsupported Transfer-Encoding")
      end

      private def next_chunked_request(
        method : String,
        path : String,
        version : String,
        headers : Hash(String, String),
        offset : Int32,
      ) : HttpRequest?
        cursor = offset
        body = String::Builder.new
        loop do
          line_end = @buffer.index("\r\n", cursor)
          return nil unless line_end
          size_text = (@buffer.byte_slice(cursor, line_end - cursor) || "").split(";", 2).first
          size = parse_chunk_size(size_text)
          cursor = line_end + 2

          if size == 0
            trailer_end = @buffer.index("\r\n\r\n", cursor)
            return nil unless trailer_end
            trailer_lines = (@buffer.byte_slice(cursor, trailer_end - cursor) || "").split("\r\n")
            parsed_trailers = parse_headers(trailer_lines.empty? || trailer_lines == [""] ? [] of String : trailer_lines)
            trailers = parsed_trailers[0]
            consume(trailer_end + 4)
            return HttpRequest.new(method, path, headers, body.to_s, trailers, version)
          end

          return nil if @buffer.bytesize < cursor + size + 2
          body << (@buffer.byte_slice(cursor, size) || "")
          cursor += size
          unless @buffer.byte_slice(cursor, 2) == "\r\n"
            raise HttpProtocolError.new("invalid chunk terminator")
          end
          cursor += 2
        end
      end

      private def parse_headers(lines : Array(String)) : Tuple(Hash(String, String), Hash(String, Array(String)))
        headers = {} of String => String
        values = {} of String => Array(String)
        lines.each do |line|
          name, value = line.split(":", 2)
          if !valid_header?(name, value)
            raise HttpProtocolError.new("invalid HTTP header")
          end
          clean_value = value.strip
          headers[name] = clean_value
          normalized_name = name.downcase
          (values[normalized_name] ||= [] of String) << clean_value
        end
        {headers, values}
      end

      private def valid_header?(name : String?, value : String?) : Bool
        return false unless name && value
        !name.empty? && name.each_byte.all? { |byte| token_byte?(byte) }
      end

      private def parse_content_length(values : Array(String)) : Int32
        return 0 if values.empty?
        lengths = values.map do |value|
          unless value.matches?(/\A[0-9]+\z/)
            raise HttpProtocolError.new("invalid Content-Length")
          end
          value.to_i
        end
        raise HttpProtocolError.new("conflicting Content-Length values") unless lengths.uniq.size == 1
        lengths.first
      end

      private def parse_chunk_size(value : String) : Int32
        unless value.matches?(/\A[0-9A-Fa-f]+\z/)
          raise HttpProtocolError.new("invalid chunk size")
        end
        value.to_i(16)
      rescue OverflowError
        raise HttpProtocolError.new("invalid chunk size")
      end

      private def token_byte?(byte : UInt8) : Bool
        (byte >= '0'.ord && byte <= '9'.ord) ||
          (byte >= 'A'.ord && byte <= 'Z'.ord) ||
          (byte >= 'a'.ord && byte <= 'z'.ord) ||
          "!#$%&'*+-.^_`|~".bytes.includes?(byte)
      end

      private def consume(length : Int32) : Nil
        @buffer = @buffer.byte_slice(length, @buffer.bytesize - length) || ""
      end
    end

    # Incremental HTTP response framing without sockets. This parser deliberately
    # leaves EOF-delimited bodies and request-method-specific response framing to
    # the connection state machine introduced by the remaining conformance work.
    class HttpResponseParser
      @buffer = ""
      @eof_response : EofResponse? = nil
      @request_method : String? = nil
      @upgrade_requested = false
      @switched_protocol = false
      @trailing_data = ""

      getter trailing_data : String

      def request_method=(method : String?) : String?
        @request_method = method
      end

      def upgrade_requested=(value : Bool) : Bool
        @upgrade_requested = value
      end

      def switched_protocol? : Bool
        @switched_protocol
      end

      private struct EofResponse
        getter status : Int32
        getter reason : String
        getter version : String
        getter headers : Hash(String, String)

        def initialize(@status : Int32, @reason : String, @version : String, @headers : Hash(String, String))
        end
      end

      def feed(chunk : String, max_messages : Int32? = nil) : Array(HttpResponse)
        raise HttpProtocolError.new("HTTP parser already switched protocols") if @switched_protocol && !chunk.empty?

        @buffer += chunk
        return [] of HttpResponse if @eof_response

        responses = [] of HttpResponse
        while response = next_response
          responses << response
          break if @switched_protocol
          break if max_messages && responses.size >= max_messages
        end
        responses
      end

      # Signals a peer EOF. Only an EOF-delimited response can complete here.
      def finish : Array(HttpResponse)
        unless response = @eof_response
          raise HttpProtocolError.new("unexpected EOF in HTTP response") unless @buffer.empty?
          return [] of HttpResponse
        end

        @eof_response = nil
        body = @buffer
        @buffer = ""
        [HttpResponse.new(response.status, response.reason, response.headers, body, http_version: response.version)]
      end

      private def next_response : HttpResponse?
        header_end = @buffer.index("\r\n\r\n")
        return nil unless header_end

        status, reason, version, headers, values = parse_response_head(header_end)
        body_start = header_end + 4
        if bodyless_status?(status) || @request_method == "HEAD" || successful_connect?(status)
          return consume_bodyless_response(status, reason, version, headers, values, body_start)
        end

        content_lengths = values["content-length"]? || [] of String
        transfer_encodings = values["transfer-encoding"]? || [] of String
        validate_response_framing!(content_lengths, transfer_encodings)
        return next_chunked_response(status, reason, version, headers, body_start) unless transfer_encodings.empty?
        return defer_eof_response(status, reason, version, headers, body_start) if content_lengths.empty?

        content_length = parse_content_length(content_lengths)
        total_length = body_start + content_length
        return nil if @buffer.bytesize < total_length

        body = @buffer.byte_slice(body_start, content_length) || ""
        consume(total_length)
        HttpResponse.new(status, reason, headers, body, http_version: version)
      end

      private def parse_response_head(header_end : Int32) : Tuple(Int32, String, String, Hash(String, String), Hash(String, Array(String)))
        header_block = @buffer.byte_slice(0, header_end) || ""
        lines = header_block.split("\r\n")
        status, reason, version = parse_response_line(lines.shift? || raise HttpProtocolError.new("missing status line"))
        headers, values = parse_headers(lines)
        {status, reason, version, headers, values}
      end

      private def parse_response_line(line : String) : Tuple(Int32, String, String)
        version, raw_status, reason = line.split(" ", 3)
        unless (version == "HTTP/1.0" || version == "HTTP/1.1") && raw_status && raw_status.matches?(/\A[0-9]{3}\z/)
          raise HttpProtocolError.new("invalid HTTP response line")
        end
        {raw_status.to_i, reason || "", version}
      end

      private def consume_bodyless_response(
        status : Int32,
        reason : String,
        version : String,
        headers : Hash(String, String),
        values : Hash(String, Array(String)),
        body_start : Int32,
      ) : HttpResponse
        content_lengths = values["content-length"]? || [] of String
        length = @request_method == "HEAD" ? parse_content_length(content_lengths) : 0
        consume(body_start + length)
        capture_protocol_switch! if upgrade_switch?(status) || successful_connect?(status)
        HttpResponse.new(status, reason, headers, "", http_version: version)
      end

      private def successful_connect?(status : Int32) : Bool
        @request_method == "CONNECT" && status >= 200 && status < 300
      end

      private def upgrade_switch?(status : Int32) : Bool
        status == 101 && @upgrade_requested
      end

      private def capture_protocol_switch! : Nil
        @switched_protocol = true
        @trailing_data = @buffer
        @buffer = ""
      end

      private def bodyless_status?(status : Int32) : Bool
        (100..199).includes?(status) || status == 204 || status == 304
      end

      private def validate_response_framing!(content_lengths : Array(String), transfer_encodings : Array(String)) : Nil
        if !content_lengths.empty? && !transfer_encodings.empty?
          raise HttpProtocolError.new("response has both Transfer-Encoding and Content-Length")
        end
        return if transfer_encodings.empty?
        return if transfer_encodings.size == 1 && transfer_encodings.first.downcase == "chunked"

        raise HttpProtocolError.new("unsupported Transfer-Encoding")
      end

      private def defer_eof_response(
        status : Int32,
        reason : String,
        version : String,
        headers : Hash(String, String),
        body_start : Int32,
      ) : Nil
        consume(body_start)
        @eof_response = EofResponse.new(status, reason, version, headers)
        nil
      end

      private def next_chunked_response(
        status : Int32,
        reason : String,
        version : String,
        headers : Hash(String, String),
        offset : Int32,
      ) : HttpResponse?
        cursor = offset
        body = String::Builder.new
        loop do
          line_end = @buffer.index("\r\n", cursor)
          return nil unless line_end
          size_text = (@buffer.byte_slice(cursor, line_end - cursor) || "").split(";", 2).first
          size = parse_chunk_size(size_text)
          cursor = line_end + 2

          if size == 0
            trailer_end = @buffer.index("\r\n\r\n", cursor)
            return nil unless trailer_end
            trailer_lines = (@buffer.byte_slice(cursor, trailer_end - cursor) || "").split("\r\n")
            parsed_trailers = parse_headers(trailer_lines.empty? || trailer_lines == [""] ? [] of String : trailer_lines)
            consume(trailer_end + 4)
            return HttpResponse.new(status, reason, headers, body.to_s, parsed_trailers[0], version)
          end

          return nil if @buffer.bytesize < cursor + size + 2
          body << (@buffer.byte_slice(cursor, size) || "")
          cursor += size
          unless @buffer.byte_slice(cursor, 2) == "\r\n"
            raise HttpProtocolError.new("invalid chunk terminator")
          end
          cursor += 2
        end
      end

      private def parse_headers(lines : Array(String)) : Tuple(Hash(String, String), Hash(String, Array(String)))
        headers = {} of String => String
        values = {} of String => Array(String)
        lines.each do |line|
          name, value = line.split(":", 2)
          if !valid_header?(name, value)
            raise HttpProtocolError.new("invalid HTTP header")
          end
          clean_value = value.strip
          headers[name] = clean_value
          normalized_name = name.downcase
          (values[normalized_name] ||= [] of String) << clean_value
        end
        {headers, values}
      end

      private def valid_header?(name : String?, value : String?) : Bool
        return false unless name && value
        !name.empty? && name.each_byte.all? { |byte| token_byte?(byte) }
      end

      private def parse_content_length(values : Array(String)) : Int32
        return 0 if values.empty?
        lengths = values.map do |value|
          unless value.matches?(/\A[0-9]+\z/)
            raise HttpProtocolError.new("invalid Content-Length")
          end
          value.to_i
        end
        raise HttpProtocolError.new("conflicting Content-Length values") unless lengths.uniq.size == 1
        lengths.first
      end

      private def parse_chunk_size(value : String) : Int32
        unless value.matches?(/\A[0-9A-Fa-f]+\z/)
          raise HttpProtocolError.new("invalid chunk size")
        end
        value.to_i(16)
      rescue OverflowError
        raise HttpProtocolError.new("invalid chunk size")
      end

      private def token_byte?(byte : UInt8) : Bool
        (byte >= '0'.ord && byte <= '9'.ord) ||
          (byte >= 'A'.ord && byte <= 'Z'.ord) ||
          (byte >= 'a'.ord && byte <= 'z'.ord) ||
          "!#$%&'*+-.^_`|~".bytes.includes?(byte)
      end

      private def consume(length : Int32) : Nil
        @buffer = @buffer.byte_slice(length, @buffer.bytesize - length) || ""
      end
    end

    # Role-aware Sans-I/O HTTP/1 connection coordinator. It only consumes and
    # emits bytes/messages; socket ownership remains at the platform edge.
    class HttpConnection
      alias Message = HttpRequest | HttpResponse

      @request_parser = HttpParser.new
      @response_parser = HttpResponseParser.new
      @pending_requests = [] of HttpRequest
      @expected_response_methods = [] of String
      @expected_response_upgrades = [] of Bool
      @incomplete_input = ""
      @switched_protocol = false
      @trailing_data = ""
      @active_request : HttpRequest? = nil

      def initialize(@role : HttpRole, @limits : HttpLimits = HttpLimits.new)
      end

      def receive(chunk : String) : Array(Message)
        raise HttpProtocolError.new("HTTP parser already switched protocols") if @switched_protocol && !chunk.empty?

        track_incomplete_input(chunk)
        messages = @role.server? ? receive_requests(chunk) : receive_responses(chunk)
        @incomplete_input = "" unless messages.empty?
        messages
      end

      def send_request(
        method : String,
        path : String,
        body : String,
        headers : Hash(String, String) = {} of String => String,
      ) : String
        raise HttpProtocolError.new("only a client connection can send requests") unless @role.client?

        @expected_response_methods << method
        @expected_response_upgrades << headers.any? { |name, _| name.downcase == "upgrade" }
        HttpSerializer.request(method, path, body, headers)
      end

      def send_response(
        status : Int32,
        reason : String,
        body : String,
        headers : Hash(String, String) = {} of String => String,
      ) : String
        raise HttpProtocolError.new("only a server connection can send responses") unless @role.server?
        request = @active_request || raise HttpProtocolError.new("no active request for response")

        @switched_protocol = true if accepts_protocol_switch?(request, status)
        @active_request = nil unless (100..199).includes?(status) && status != 101
        HttpSerializer.response(status, reason, body, headers)
      end

      def start_next_cycle : Array(Message)
        return [] of Message unless @role.server?
        return [] of Message if @active_request
        return [] of Message if @pending_requests.empty?

        request = @pending_requests.shift
        @active_request = request
        [request.as(Message)]
      end

      def paused? : Bool
        @role.server? && !@pending_requests.empty?
      end

      def switched_protocol? : Bool
        @switched_protocol
      end

      getter trailing_data : String

      def finish : Array(Message)
        if @role.server?
          @request_parser.finish.map { |request| request.as(Message) }
        else
          @response_parser.finish.map { |response| response.as(Message) }
        end
      end

      private def receive_requests(chunk : String) : Array(Message)
        requests = @request_parser.feed(chunk)
        @pending_requests.concat(requests)
        start_next_cycle
      end

      private def receive_responses(chunk : String) : Array(Message)
        responses = [] of HttpResponse
        next_chunk = chunk
        loop do
          @response_parser.request_method = @expected_response_methods.first?
          @response_parser.upgrade_requested = @expected_response_upgrades.first? || false
          parsed = @response_parser.feed(next_chunk, 1)
          next_chunk = ""
          break if parsed.empty?

          response = parsed.first
          responses << response
          if response.status >= 200 || @response_parser.switched_protocol?
            @expected_response_methods.shift
            @expected_response_upgrades.shift
          end
          break if @response_parser.switched_protocol?
        end
        if @response_parser.switched_protocol?
          @switched_protocol = true
          @trailing_data = @response_parser.trailing_data
        end
        responses.map { |response| response.as(Message) }
      end

      private def track_incomplete_input(chunk : String) : Nil
        @incomplete_input += chunk
        if !@incomplete_input.includes?("\r\n\r\n") && @incomplete_input.bytesize > @limits.max_header_bytes
          raise HttpProtocolError.new("header exceeds configured limit")
        end
        return unless @incomplete_input.bytesize > @limits.max_incomplete_bytes

        raise HttpProtocolError.new("incomplete message exceeds configured limit")
      end

      private def accepts_protocol_switch?(request : HttpRequest, status : Int32) : Bool
        return true if request.method == "CONNECT" && status >= 200 && status < 300
        return false unless status == 101

        request.headers.any? { |name, _| name.downcase == "upgrade" }
      end
    end

    module HttpSerializer
      extend self

      def request(method : String, path : String, body : String, headers : Hash(String, String) = {} of String => String) : String
        serialized_headers = headers.reject { |name, _| name == "Content-Length" }
        lines = ["#{method} #{path} HTTP/1.1"]
        serialized_headers.keys.sort!.each do |name|
          lines << "#{name}: #{serialized_headers[name]}"
        end
        lines << "Content-Length: #{body.bytesize}"
        "#{lines.join("\r\n")}\r\n\r\n#{body}"
      end

      def response(status : Int32, reason : String, body : String, headers : Hash(String, String) = {} of String => String) : String
        serialized_headers = headers.reject { |name, _| name == "Content-Length" }
        lines = ["HTTP/1.1 #{status} #{reason}"]
        serialized_headers.keys.sort!.each do |name|
          lines << "#{name}: #{serialized_headers[name]}"
        end
        lines << "Content-Length: #{body.bytesize}"
        "#{lines.join("\r\n")}\r\n\r\n#{body}"
      end
    end
  end
end
