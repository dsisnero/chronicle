require "../spec_helper"

# Adapted from h11/h11/tests/test_connection.py at 62c5068c971579d61fa1b55373390e12f25fd856,
# test_chunk_boundaries and test_pipelining (MIT; https://github.com/python-hyper/h11).
# Normalized to this adapter's complete-message API on 2026-07-24.
H11_HTTP_FIXTURE_SOURCE = "python-hyper/h11@62c5068c971579d61fa1b55373390e12f25fd856:h11/tests/test_connection.py (MIT)"

describe Clarity::SansIO::HttpConnectionPolicy do
  # Adapted from h11/h11/tests/test_connection.py at
  # 62c5068c971579d61fa1b55373390e12f25fd856, test__keep_alive (MIT;
  # https://github.com/python-hyper/h11). Normalized to a pure policy API on
  # 2026-07-24.
  it "keeps HTTP/1.1 connections alive by default" do
    Clarity::SansIO::HttpConnectionPolicy.keep_alive?("HTTP/1.1", {"Host" => "example.com"}).should be_true
  end

  it "recognizes a case-insensitive close token among connection tokens" do
    Clarity::SansIO::HttpConnectionPolicy.keep_alive?(
      "HTTP/1.1",
      {"Connection" => "a, b, cLOse, foo"}
    ).should be_false
  end

  it "does not keep HTTP/1.0 connections alive" do
    Clarity::SansIO::HttpConnectionPolicy.keep_alive?("HTTP/1.0", {} of String => String).should be_false
  end
end

describe Clarity::SansIO::HttpParser do
  it "emits a request only after its complete body arrives" do
    parser = Clarity::SansIO::HttpParser.new
    request = "POST /events HTTP/1.1\r\nHost: localhost\r\nContent-Length: 7\r\n\r\n{\"x\":1}"

    parser.feed(request[0, 32]).should be_empty
    frames = parser.feed(request[32..])

    frames.size.should eq(1)
    frames.first.method.should eq("POST")
    frames.first.path.should eq("/events")
    frames.first.headers["Host"].should eq("localhost")
    frames.first.body.should eq(%({"x":1}))
  end

  it "serializes a complete outbound HTTP request deterministically" do
    output = Clarity::SansIO::HttpSerializer.request(
      "POST",
      "/events",
      %({"x":1}),
      {"Host" => "localhost"}
    )

    output.should eq("POST /events HTTP/1.1\r\nHost: localhost\r\nContent-Length: 7\r\n\r\n{\"x\":1}")
  end

  it "frames pipelined requests without losing a following message" do
    parser = Clarity::SansIO::HttpParser.new
    requests = parser.feed(
      "POST /one HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\none" \
      "GET /two HTTP/1.1\r\nHost: example.com\r\n\r\n"
    )

    requests.map(&.path).should eq(["/one", "/two"])
    requests.map(&.body).should eq(["one", ""])
  end

  it "frames a chunked body and retains trailers" do
    parser = Clarity::SansIO::HttpParser.new

    parser.feed("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel").should be_empty
    frames = parser.feed("lo\r\n6\r\n world\r\n0\r\nX-Checksum: ok\r\n\r\n")

    frames.size.should eq(1)
    frames.first.body.should eq("hello world")
    frames.first.trailers.should eq({"X-Checksum" => "ok"})
  end

  it "rejects ambiguous transfer-encoding and content-length framing" do
    parser = Clarity::SansIO::HttpParser.new

    expect_raises(Clarity::SansIO::HttpProtocolError, /both Transfer-Encoding and Content-Length/) do
      parser.feed("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n")
    end
  end

  it "rejects conflicting content-length values" do
    parser = Clarity::SansIO::HttpParser.new

    expect_raises(Clarity::SansIO::HttpProtocolError, /conflicting Content-Length/) do
      parser.feed("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n")
    end
  end
end

describe Clarity::SansIO::HttpResponseParser do
  # Adapted from h11/h11/tests/test_connection.py at
  # 62c5068c971579d61fa1b55373390e12f25fd856, test__body_framing (MIT;
  # https://github.com/python-hyper/h11). Normalized to complete response
  # messages on 2026-07-24.
  it "emits a response only after its content-length body arrives" do
    parser = Clarity::SansIO::HttpResponseParser.new

    parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel").should be_empty
    responses = parser.feed("lo")

    responses.size.should eq(1)
    responses.first.status.should eq(200)
    responses.first.reason.should eq("OK")
    responses.first.body.should eq("hello")
  end

  it "treats 204 responses as bodyless despite framing headers" do
    parser = Clarity::SansIO::HttpResponseParser.new
    responses = parser.feed(
      "HTTP/1.1 204 No Content\r\nContent-Length: 99\r\n\r\n" \
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
    )

    responses.map(&.status).should eq([204, 200])
    responses.map(&.body).should eq(["", "ok"])
  end

  it "frames an incremental chunked response and retains trailers" do
    parser = Clarity::SansIO::HttpResponseParser.new

    parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel").should be_empty
    responses = parser.feed("lo\r\n0\r\nX-Checksum: ok\r\n\r\n")

    responses.first.body.should eq("hello")
    responses.first.trailers.should eq({"X-Checksum" => "ok"})
  end

  it "waits for EOF to complete an unframed response body" do
    parser = Clarity::SansIO::HttpResponseParser.new

    parser.feed("HTTP/1.0 200 OK\r\n\r\nhel").should be_empty
    parser.feed("lo").should be_empty
    responses = parser.finish

    responses.first.body.should eq("hello")
    responses.first.http_version.should eq("HTTP/1.0")
  end

  it "rejects ambiguous response transfer and content-length framing" do
    parser = Clarity::SansIO::HttpResponseParser.new

    expect_raises(Clarity::SansIO::HttpProtocolError, /both Transfer-Encoding and Content-Length/) do
      parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n")
    end
  end
end
