require "../spec_helper"

# Adapted from h11/h11/tests/test_connection.py at 62c5068c971579d61fa1b55373390e12f25fd856,
# test_chunk_boundaries and test_pipelining (MIT; https://github.com/python-hyper/h11).
# Normalized to this adapter's complete-message API on 2026-07-24.
H11_HTTP_FIXTURE_SOURCE = "python-hyper/h11@62c5068c971579d61fa1b55373390e12f25fd856:h11/tests/test_connection.py (MIT)"

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
