# frozen_string_literal: true

require "socket"
require "json"
require "uri"

# A local stand-in for Slack's Web API, for tests that drive the real slack-ruby-client over HTTP.
# Every request is recorded as [method, params]; each answer is `{ "ok" => true }` unless the test
# queued a Slack error code for that method with #refuse.
#
#   api = FakeSlackWebApi.start
#   SlackService.stubs(:client).returns(api.client)
#   ...
#   api.calls # => [["chat.postMessage", { "channel" => "C1", "thread_ts" => "1.0", "text" => "..." }]]
class FakeSlackWebApi
  attr_reader :calls

  def self.start
    new.tap(&:start)
  end

  def initialize
    @calls = []
    @refusals = {}
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { loop { serve(@server.accept) } rescue IOError }
    self
  end

  def stop
    @server&.close
    @thread&.join(2)
  end

  def endpoint
    "http://127.0.0.1:#{@server.addr[1]}/api/"
  end

  # A real client, pointed here.
  def client
    Slack::Web::Client.new(token: "xoxb-fake", endpoint: endpoint, open_timeout: 2, timeout: 5)
  end

  # Answer the next call to `method` with `{ ok: false, error: code }`.
  def refuse(method, code)
    @mutex.synchronize { @refusals[method] = code }
  end

  private

  def serve(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s
    method = request_line.split[1].to_s.split("?").first.delete_prefix("/api/")
    params = URI.decode_www_form(body).to_h

    payload = @mutex.synchronize do
      @calls << [ method, params ]
      code = @refusals.delete(method)
      code ? { "ok" => false, "error" => code } : { "ok" => true, "channel" => params["channel"], "ts" => "1800000000.000200" }
    end

    text = JSON.generate(payload)
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  rescue StandardError
    # A client that hung up must not take the accept loop down with it.
    nil
  ensure
    socket.close
  end
end
