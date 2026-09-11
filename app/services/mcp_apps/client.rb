# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module McpApps
  # A minimal MCP client for the Streamable HTTP transport, speaking exactly the
  # four requests this feature needs: `initialize`, `tools/list`, `resources/read`
  # and `tools/call`.
  #
  # Why not a gem: the `mcp` gem Zimmer already depends on implements the SERVER
  # half of the protocol (it is what `POST /mcp` is built on) and ships no client.
  # The spike shelled out to a Node bridge instead, which is a process spawn per
  # fragment in the request path. The client surface needed here is four calls
  # over one POST shape, so it is written out.
  #
  # Everything about this class is bounded on purpose, because it runs inside a
  # web request against a server Zimmer does not operate: connect and read
  # timeouts, a response byte cap, and no redirect following (an MCP endpoint that
  # answers a POST with a redirect is not one this feature talks to).
  class Client
    class Error < StandardError; end

    # The server answered, and answered with a JSON-RPC error. Carries the code so
    # the proxy can pass a faithful error back to the view instead of flattening
    # everything to "something went wrong".
    class RpcError < Error
      attr_reader :code

      def initialize(message, code: nil)
        super(message)
        @code = code
      end
    end

    # What #post hands back: the bytes it was willing to read, and the content
    # type that says how to read them. Not a Net::HTTPResponse, because the body
    # is consumed inside the request block and the response object no longer
    # carries it afterwards.
    Response = Data.define(:body, :content_type)

    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 20

    # A fragment is a document; a tool result is a page of JSON. Two megabytes is
    # far past either and still small enough that a server answering with a stream
    # of garbage cannot exhaust the web process.
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024

    # What Zimmer tells the server it is. `elicitation`, `sampling` and `roots` are
    # deliberately absent: this host answers none of them, and declaring a
    # capability it cannot serve is how a server ends up waiting on a reply that
    # never comes.
    CLIENT_INFO = { "name" => "zimmer", "title" => "Zimmer", "version" => Mcp::SERVER_VERSION }.freeze

    # The protocol revision the TRANSPORT speaks, which is not the MCP Apps
    # revision in McpApps::PROTOCOL_VERSION.
    MCP_PROTOCOL_VERSION = "2025-06-18"

    # The server's own `serverInfo`, populated by the `initialize` handshake and
    # nil until one has happened.
    attr_reader :server_info

    # @param url [String] the server's Streamable HTTP endpoint
    # @param headers [Hash] fully resolved request headers (auth included)
    def initialize(url:, headers: {})
      @uri = URI.parse(url.to_s)
      raise Error, "MCP server url must be http(s): #{url}" unless @uri.is_a?(URI::HTTP)

      @headers = headers.to_h { |key, value| [ key.to_s, value.to_s ] }
      @next_id = 0
      @initialized = false
    end

    # @return [Array<Hash>] the server's tools, as `tools/list` returned them
    def tools_list
      collect_paginated("tools/list", "tools")
    end

    # @return [Array<Hash>] the server's resources, as `resources/list` returned them
    def resources_list
      collect_paginated("resources/list", "resources")
    end

    # @param uri [String] the resource URI to read
    # @return [Hash] the `resources/read` result
    def resources_read(uri)
      request("resources/read", { "uri" => uri })
    end

    # @param name [String] tool name, as the server names it (no `mcp__` prefix)
    # @param arguments [Hash]
    # @return [Hash] the `tools/call` result
    def call_tool(name, arguments)
      request("tools/call", { "name" => name, "arguments" => arguments || {} })
    end

    private

    # Walk `nextCursor` so a server with more tools than fit in one page does not
    # silently hide the one that declares the view.
    def collect_paginated(method, key)
      items = []
      cursor = nil

      # A server that returns a cursor forever would otherwise spin here.
      10.times do
        params = cursor ? { "cursor" => cursor } : {}
        result = request(method, params)
        page = result[key]
        items.concat(page) if page.is_a?(Array)
        cursor = result["nextCursor"]
        break if cursor.blank?
      end

      items
    end

    def request(method, params)
      ensure_initialized!
      rpc(method, params)
    end

    def ensure_initialized!
      return if @initialized

      result = rpc("initialize", {
        "protocolVersion" => MCP_PROTOCOL_VERSION,
        "capabilities" => {},
        "clientInfo" => CLIENT_INFO
      })
      @server_info = result["serverInfo"] if result.is_a?(Hash)
      @initialized = true
      notify("notifications/initialized")
    end

    def rpc(method, params)
      @next_id += 1
      body = { "jsonrpc" => "2.0", "id" => @next_id, "method" => method, "params" => params || {} }
      response = post(body)
      message = extract_message(response, @next_id)

      raise Error, "no response to #{method}" if message.nil?

      if (error = message["error"])
        raise RpcError.new(error["message"].presence || "#{method} failed", code: error["code"])
      end

      result = message["result"]
      result.is_a?(Hash) ? result : {}
    end

    def notify(method, params = {})
      post({ "jsonrpc" => "2.0", "method" => method, "params" => params })
    rescue Error => e
      # A notification has no reply to wait on and nothing downstream depends on
      # it landing. A server that rejects `notifications/initialized` is not a
      # reason to fail the read the caller actually asked for.
      Rails.logger.debug("[mcp-apps] notification #{method} failed: #{e.message}")
      nil
    end

    def post(body)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      post = Net::HTTP::Post.new(@uri.request_uri)
      @headers.each { |key, value| post[key] = value }
      post["Content-Type"] = "application/json"
      post["Accept"] = "application/json, text/event-stream"
      post["MCP-Protocol-Version"] = MCP_PROTOCOL_VERSION
      post["Mcp-Session-Id"] = @session_id if @session_id
      post.body = JSON.generate(body)

      # The body is read in chunks and abandoned the moment it passes the cap,
      # rather than read whole and measured afterwards. A server Zimmer does not
      # operate can answer with a stream that never ends; measuring after the
      # fact would mean it had already been in memory.
      result = nil
      body = +""
      truncated = false

      http.request(post) do |response|
        result = response
        @session_id ||= response["Mcp-Session-Id"]

        response.read_body do |chunk|
          body << chunk
          if body.bytesize > MAX_RESPONSE_BYTES
            truncated = true
            break
          end
        end
      end

      raise Error, "MCP response exceeded #{MAX_RESPONSE_BYTES} bytes" if truncated

      unless result.is_a?(Net::HTTPSuccess)
        raise Error, "MCP server returned HTTP #{result.code}"
      end

      Response.new(body: body, content_type: result["Content-Type"].to_s)
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Error, "MCP server did not answer within #{READ_TIMEOUT_SECONDS}s"
    rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
      raise Error, "could not reach MCP server: #{e.class}"
    end

    # Pull the JSON-RPC message out of whichever body shape the server chose.
    # Streamable HTTP lets a server answer one POST with either a JSON object or
    # an SSE stream carrying the reply among any notifications it wants to send
    # first, so both have to be read.
    def extract_message(response, id)
      return nil if response.body.empty?

      if response.content_type.include?("text/event-stream")
        message_from_sse(response.body, id)
      else
        parsed = parse_json(response.body)
        parsed.is_a?(Array) ? parsed.find { |m| m.is_a?(Hash) && m["id"] == id } : parsed
      end
    end

    def message_from_sse(body, id)
      fallback = nil

      body.each_line do |line|
        next unless line.start_with?("data:")

        payload = line.delete_prefix("data:").strip
        next if payload.empty?

        message = begin
          JSON.parse(payload)
        rescue JSON::ParserError
          next
        end
        next unless message.is_a?(Hash)
        return message if message["id"] == id

        # A reply with no id at all is not one we asked for, but some servers
        # echo errors that way; hold it in case nothing better arrives.
        fallback ||= message if message.key?("error")
      end

      fallback
    end

    def parse_json(body)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error, "MCP server returned unparseable JSON: #{e.message}"
    end
  end
end
