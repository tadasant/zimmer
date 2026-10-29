# frozen_string_literal: true

require "socket"

# An MCP server that publishes events through the MCP Events extension's poll mode (SEP-3415), for
# tests, reached over real HTTP through McpEvents::Client.
#
# It answers the way strad's gateway answers for its Slack mount: the extension declared under
# `capabilities.extensions` in `initialize`, one event type `slack-zimmer__message_posted` under the
# gateway's slug prefix, `eventId`s of the form `slack:<channel>:<ts>`, and an opaque cursor over a
# buffer. A null cursor means "from now": no events, and the cursor at the buffer's end.
#
#   server = FakeEventsMcpServer.start
#   server.publish(channel_id: "C0123", ts: "1793000000.000100", text: "<@UBOT> hi", mentions_bot: true)
#   server.url  # => http://127.0.0.1:<port>/mcp?servers=slack-zimmer
#   server.stop
class FakeEventsMcpServer
  SLUG = "slack-zimmer"
  EVENT_NAME = "#{SLUG}__message_posted".freeze

  Call = Data.define(:method, :params, :headers)

  attr_reader :calls
  # A JSON-RPC error to answer every events/* call with, e.g. [-32024, "Forbidden"].
  attr_accessor :refuse
  # Whether `initialize` declares the extension.
  attr_accessor :declares_events
  # nextPollMs on every poll answer.
  attr_accessor :next_poll_ms
  # The oldest seq still held; a cursor before it is answered with truncated: true.
  attr_accessor :retention_floor
  # The most events one poll answer carries, whatever maxEvents asks for — so a test can make
  # the poller follow hasMore.
  attr_accessor :page_size

  def self.start
    new.tap(&:start)
  end

  def initialize
    @events = []
    @calls = []
    @refuse = nil
    @declares_events = true
    @next_poll_ms = nil
    @retention_floor = 0
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

  def url
    "http://127.0.0.1:#{@server.addr[1]}/mcp?servers=#{SLUG}"
  end

  def publish(channel_id:, ts:, text: "hello", user_id: "U0AAAAAAA", thread_ts: nil, is_dm: false, mentions_bot: false)
    @mutex.synchronize do
      @events << {
        "eventId" => "slack:#{channel_id}:#{ts}",
        "name" => EVENT_NAME,
        "timestamp" => Time.current.iso8601,
        "data" => {
          "channel_id" => channel_id, "channel_type" => is_dm ? "im" : "channel", "ts" => ts,
          "thread_ts" => thread_ts, "user_id" => user_id, "is_dm" => is_dm, "mentions_bot" => mentions_bot,
          "permalink" => "https://example.slack.com/archives/#{channel_id}/p#{ts.delete('.')}", "text" => text
        }.compact
      }
    end
  end

  def polls
    @mutex.synchronize { @calls.select { |call| call.method == "events/poll" } }
  end

  private

  def serve(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i)
    status, payload = request_line.start_with?("POST") ? dispatch(JSON.parse(body), headers) : [ 405, nil ]

    text = payload ? JSON.generate(payload) : ""
    reason = { 200 => "OK", 202 => "Accepted", 405 => "Method Not Allowed" }.fetch(status)
    socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  ensure
    socket.close
  end

  def dispatch(message, headers)
    return [ 202, nil ] unless message.key?("id")

    @mutex.synchronize { @calls << Call.new(method: message["method"], params: message["params"], headers: headers) }
    params = message["params"] || {}
    if refuse && message["method"].to_s.start_with?("events/")
      return [ 200, { "jsonrpc" => "2.0", "id" => message["id"], "error" => { "code" => refuse[0], "message" => refuse[1] } } ]
    end

    result = case message["method"]
    when "initialize"
      capabilities = { "tools" => {} }
      capabilities["extensions"] = { McpEvents::EXTENSION_ID => {} } if declares_events
      { "protocolVersion" => "2025-06-18", "capabilities" => capabilities, "serverInfo" => { "name" => "fake-events", "version" => "0" } }
    when "events/list"
      { "events" => [ descriptor ] }
    when "events/poll"
      poll(params)
    end
    [ 200, { "jsonrpc" => "2.0", "id" => message["id"], "result" => result } ]
  end

  def descriptor
    {
      "name" => EVENT_NAME,
      "description" => "A message was posted in a conversation the bot is in.",
      "delivery" => [ "poll" ],
      "inputSchema" => { "type" => "object", "properties" => { "addressed_to_bot" => { "type" => "boolean" } } },
      "payloadSchema" => { "type" => "object", "properties" => { "channel_id" => { "type" => "string" }, "text" => { "type" => "string" } } }
    }
  end

  def poll(params)
    @mutex.synchronize do
      head = @events.size
      cursor = params["cursor"]
      return { "events" => [], "cursor" => "seq:#{head}", "truncated" => false, "hasMore" => false, "nextPollMs" => next_poll_ms }.compact if cursor.nil?

      from = cursor.to_s.delete_prefix("seq:").to_i
      truncated = from < retention_floor
      from = retention_floor if truncated
      max = [ (params["maxEvents"] || 50).to_i, page_size || 1_000 ].min
      window = @events[from, max] || []
      addressed = params.dig("arguments", "addressed_to_bot") == true
      matching = window.select { |event| !addressed || event["data"]["mentions_bot"] || event["data"]["is_dm"] }
      next_from = from + window.size
      { "events" => matching, "cursor" => "seq:#{next_from}", "truncated" => truncated,
        "hasMore" => next_from < head, "nextPollMs" => next_poll_ms }.compact
    end
  end
end
