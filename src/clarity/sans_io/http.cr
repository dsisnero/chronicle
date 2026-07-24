module Clarity
  module SansIO
    class HttpProtocolError < Exception
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

    # Incremental HTTP request framing without sockets or other system
    # capabilities. The complete HTTP/1 connection state machine is delivered
    # separately; this adapter preserves complete inbound request boundaries.
    class HttpParser
      @buffer = ""

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
    end
  end
end
