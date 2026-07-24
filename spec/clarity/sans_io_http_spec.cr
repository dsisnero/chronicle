require "../spec_helper"

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
end
