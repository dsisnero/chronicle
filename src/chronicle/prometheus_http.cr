require "http/server"

module Chronicle
  module Prometheus
    # Platform-edge HTTP adapter for the Sans-IO Prometheus renderer. It binds
    # only when #start is called and exposes one deliberately small scrape
    # surface: GET /metrics.
    class ScrapeServer
      METRICS_PATH         = "/metrics"
      METRICS_CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"
      ERROR_CONTENT_TYPE   = "text/plain; charset=utf-8"

      getter address : Socket::IPAddress?

      def initialize(
        @metrics : PrometheusMetrics,
        @host : String = "127.0.0.1",
        @port : Int32 = 0,
        max_request_line_size : Int32 = 8_192,
        max_headers_size : Int32 = 8_192,
      )
        raise ArgumentError.new("max_request_line_size must be positive") unless max_request_line_size > 0
        raise ArgumentError.new("max_headers_size must be positive") unless max_headers_size > 0

        @server = HTTP::Server.new { |context| handle(context) }
        @server.max_request_line_size = max_request_line_size
        @server.max_headers_size = max_headers_size
      end

      # Binds and starts accepting requests in a fiber. The returned address
      # is useful for lifecycle-managed embedding and integration tests.
      def start : Socket::IPAddress
        raise "Prometheus scrape server is already started" if @address

        address = @server.bind_tcp(@host, @port)
        @address = address
        spawn do
          @server.listen
        rescue
          # #close can win the race before the spawned listener begins; no
          # request was accepted in that case and the endpoint is closed.
        end
        until @server.listening? || @server.closed?
          Fiber.yield
        end
        address
      end

      # Stops accepting new requests. Repeated shutdown is harmless for
      # application lifecycle hooks and test cleanup.
      def close : Nil
        @server.close unless @server.closed?
      end

      delegate closed?, to: @server

      private def handle(context : HTTP::Server::Context) : Nil
        if context.request.method != "GET"
          context.response.status_code = 405
          context.response.headers["Allow"] = "GET"
          context.response.headers["Content-Type"] = ERROR_CONTENT_TYPE
          context.response.print "method not allowed\n"
        elsif context.request.path != METRICS_PATH
          context.response.status_code = 404
          context.response.headers["Content-Type"] = ERROR_CONTENT_TYPE
          context.response.print "not found\n"
        else
          context.response.status_code = 200
          context.response.headers["Content-Type"] = METRICS_CONTENT_TYPE
          context.response.print Prometheus.render(@metrics)
        end
      end
    end
  end
end
