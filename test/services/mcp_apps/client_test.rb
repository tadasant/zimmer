# frozen_string_literal: true

require "test_helper"
require "socket"

# The client is the one piece of this feature that speaks to something outside
# Zimmer, so it is tested against a real socket rather than a stubbed Net::HTTP:
# the transport details that actually break — an SSE body instead of a JSON one,
# a session id header that has to be echoed back, a JSON-RPC error frame buried
# in a stream — are exactly the ones a stub would paper over.
class McpApps::ClientTest < ActiveSupport::TestCase
  # A single-threaded HTTP server that answers each request from a block.
  # Deliberately local to this file: it is a fixture for one class, not a suite
  # utility, and test/support is loaded by every run.
  class StubServer
    attr_reader :requests

    def initialize(&responder)
      @responder = responder
      @requests = []
      @socket = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { accept_loop }
    end

    def url = "http://127.0.0.1:#{@socket.addr[1]}/mcp"

    def stop
      @socket.close
      @thread.join(2)
    rescue IOError
      nil
    end

    private

    def accept_loop
      loop { serve(@socket.accept) }
    rescue IOError, Errno::EBADF, Errno::ECONNABORTED
      nil
    end

    def serve(connection)
      connection.gets # request line
      headers = {}
      while (line = connection.gets) && line.strip != ""
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end

      body = JSON.parse(connection.read(headers["content-length"].to_i))
      @requests << { body: body, headers: headers }

      status, response_headers, response_body = @responder.call(body)
      out = +"HTTP/1.1 #{status} OK\r\n"
      response_headers.each { |name, value| out << "#{name}: #{value}\r\n" }
      out << "Content-Length: #{response_body.bytesize}\r\n"
      out << "Connection: close\r\n\r\n"
      out << response_body
      connection.write(out)
    rescue StandardError
      nil
    ensure
      connection.close rescue nil
    end
  end

  teardown do
    @server&.stop
  end

  def start(&responder)
    @server = StubServer.new(&responder)
  end

  def reply(body, result)
    JSON.generate({ "jsonrpc" => "2.0", "id" => body["id"], "result" => result })
  end

  def json(body_string)
    [ 200, { "Content-Type" => "application/json" }, body_string ]
  end

  def accepted
    [ 202, {}, "" ]
  end

  test "handshakes before the first real request, once per client" do
    start do |body|
      case body["method"]
      when "initialize"
        json(reply(body, { "protocolVersion" => "2025-06-18", "serverInfo" => { "name" => "demo" } }))
      when "tools/list"
        json(reply(body, { "tools" => [ { "name" => "roll_dice" } ] }))
      else
        accepted
      end
    end

    client = McpApps::Client.new(url: @server.url)

    assert_equal [ { "name" => "roll_dice" } ], client.tools_list

    methods = @server.requests.map { |request| request[:body]["method"] }
    assert_equal "initialize", methods.first
    assert_includes methods, "notifications/initialized"

    client.tools_list
    assert_equal 1, @server.requests.count { |r| r[:body]["method"] == "initialize" },
      "the handshake happens once per client, not once per call"
  end

  test "reads a reply out of an SSE body and ignores the notifications around it" do
    start do |body|
      next json(reply(body, {})) if body["method"] == "initialize"

      stream = [
        "event: message",
        "data: #{JSON.generate({ 'jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => {} })}",
        "",
        "data: #{reply(body, { 'contents' => [ { 'uri' => 'ui://x', 'text' => '<p>hi</p>' } ] })}",
        ""
      ].join("\n")
      [ 200, { "Content-Type" => "text/event-stream" }, stream ]
    end

    result = McpApps::Client.new(url: @server.url).resources_read("ui://x")

    assert_equal "<p>hi</p>", result["contents"].first["text"]
  end

  test "sends the session id the server issued on every later request" do
    start do |body|
      headers = { "Content-Type" => "application/json" }
      headers["Mcp-Session-Id"] = "sess-42" if body["method"] == "initialize"
      [ 200, headers, reply(body, { "tools" => [] }) ]
    end

    McpApps::Client.new(url: @server.url).tools_list

    assert_nil @server.requests.first[:headers]["mcp-session-id"]
    assert_equal "sess-42", @server.requests.last[:headers]["mcp-session-id"]
  end

  test "passes the configured credential headers through" do
    start { |body| json(reply(body, { "tools" => [] })) }

    McpApps::Client.new(url: @server.url, headers: { "Authorization" => "Bearer tok" }).tools_list

    assert_equal "Bearer tok", @server.requests.first[:headers]["authorization"]
  end

  test "a JSON-RPC error becomes an RpcError carrying the server's own code" do
    start do |body|
      next json(reply(body, {})) if body["method"] == "initialize"

      json(JSON.generate({ "jsonrpc" => "2.0", "id" => body["id"],
                           "error" => { "code" => -32602, "message" => "no such tool" } }))
    end

    error = assert_raises(McpApps::Client::RpcError) do
      McpApps::Client.new(url: @server.url).call_tool("nope", {})
    end

    assert_equal(-32602, error.code)
    assert_equal "no such tool", error.message
  end

  test "an HTTP failure is an Error, not a Net::HTTP exception" do
    start { |_body| [ 503, { "Content-Type" => "text/plain" }, "down" ] }

    assert_raises(McpApps::Client::Error) { McpApps::Client.new(url: @server.url).tools_list }
  end

  test "follows nextCursor so a paginated tool list is complete" do
    start do |body|
      case body["method"]
      when "initialize" then json(reply(body, {}))
      when "tools/list"
        if body.dig("params", "cursor") == "page2"
          json(reply(body, { "tools" => [ { "name" => "b" } ] }))
        else
          json(reply(body, { "tools" => [ { "name" => "a" } ], "nextCursor" => "page2" }))
        end
      else accepted
      end
    end

    assert_equal %w[a b], McpApps::Client.new(url: @server.url).tools_list.map { |tool| tool["name"] }
  end

  test "abandons a response past the cap instead of buffering the rest of it" do
    oversized = "x" * (McpApps::Client::MAX_RESPONSE_BYTES + 64 * 1024)
    start do |body|
      next json(reply(body, {})) if body["method"] == "initialize"

      json(oversized)
    end

    error = assert_raises(McpApps::Client::Error) { McpApps::Client.new(url: @server.url).tools_list }
    assert_match "exceeded", error.message
  end

  test "refuses a url that is not http(s)" do
    assert_raises(McpApps::Client::Error) { McpApps::Client.new(url: "file:///etc/passwd") }
  end
end
