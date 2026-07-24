module Clarity
  module SansIO
    struct HttpRequest
      getter method : String
      getter path : String
      getter headers : Hash(String, String)
      getter body : String

      def initialize(@method : String, @path : String, @headers : Hash(String, String), @body : String)
      end
    end

    # Incremental HTTP/1.1 framing without sockets or other system capabilities.
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

        header_block = @buffer.byte_slice(0, header_end) || ""
        lines = header_block.split("\r\n")
        method, path, version = lines.shift.split(" ", 3)
        raise ArgumentError.new("unsupported HTTP version") unless version == "HTTP/1.1"

        headers = {} of String => String
        lines.each do |line|
          name, value = line.split(":", 2)
          headers[name] = value.strip
        end
        length = headers["Content-Length"]?.try(&.to_i) || 0
        total_length = header_end + 4 + length
        return nil if @buffer.bytesize < total_length

        body = @buffer.byte_slice(header_end + 4, length) || ""
        @buffer = @buffer.byte_slice(total_length, @buffer.bytesize - total_length) || ""
        HttpRequest.new(method, path, headers, body)
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
