# frozen_string_literal: true

module McpApps
  # The View→Server half of the host broker, executed server-side.
  #
  # The MCP Apps protocol says a host forwards any non-`ui/` request a view makes
  # to the MCP server. The spike forwarded it from the BROWSER, which only worked
  # because the demo server answered with `Access-Control-Allow-Origin: *` — and
  # would have meant, against a real server, putting that server's credential into
  # a page that is rendering third-party HTML. So the forward happens here: the
  # view asks its host (the Zimmer page), the page asks Rails, and Rails is the
  # only party that ever holds a token.
  #
  # Two rules narrow what a view can reach through this, and both matter because
  # the view is untrusted code:
  #
  #   * **Two methods.** `tools/call` and `resources/read`. Not `tools/list` (a
  #     view is told about its own tool, not given a directory), not `prompts/*`,
  #     not `completion/*`, and nothing that can subscribe or elicit.
  #   * **App-callable tools only.** A tool is reachable only if the server marked
  #     it `visibility: ["app"]` — the spec's own way of saying "this one is for
  #     the view". A server that marks nothing exposes nothing, which is the right
  #     default: without this rule a fragment could invoke any tool the agent has,
  #     with the operator's credentials, and the first anyone would know of it is
  #     the audit log of whatever it called.
  class Proxy
    ALLOWED_METHODS = %w[tools/call resources/read].freeze

    # JSON-RPC reserved codes, used verbatim so the view's own client library
    # reports something true.
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603

    # Long enough for any resource URI, short enough that the URI is not a
    # channel for shipping a payload into a log line.
    MAX_URI_LENGTH = 2048

    Result = Data.define(:result, :code, :message) do
      def ok? = code.nil?
    end

    attr_reader :connection

    # @param connection [McpApps::ServerConnection]
    def initialize(connection)
      @connection = connection
    end

    # @param method [String] the JSON-RPC method the view asked for
    # @param params [Hash] its params
    # @return [Result]
    def call(method, params)
      params = {} unless params.is_a?(Hash)

      case method
      when "tools/call" then call_tool(params)
      when "resources/read" then read_resource(params)
      else
        failure(METHOD_NOT_FOUND, "#{method} is not forwarded by this host")
      end
    rescue ServerConnection::UnavailableError => e
      failure(METHOD_NOT_FOUND, e.message)
    rescue Client::RpcError => e
      failure(e.code || INTERNAL_ERROR, e.message)
    rescue Client::Error => e
      failure(INTERNAL_ERROR, e.message)
    end

    private

    def call_tool(params)
      name = params["name"].to_s
      return failure(INVALID_PARAMS, "tools/call needs a name") if name.empty?

      entry = ToolIndex.new(connection).entry(name)
      return failure(METHOD_NOT_FOUND, "#{name} is not a tool on this server") if entry.nil?

      unless entry.app_callable?
        return failure(
          METHOD_NOT_FOUND,
          "#{name} is not callable from a view — the server has not marked it visibility: [\"app\"]"
        )
      end

      arguments = params["arguments"]
      arguments = {} unless arguments.is_a?(Hash)

      Result.new(result: connection.client.call_tool(name, arguments), code: nil, message: nil)
    end

    def read_resource(params)
      uri = params["uri"].to_s
      return failure(INVALID_PARAMS, "resources/read needs a uri") if uri.empty?
      return failure(INVALID_PARAMS, "uri is too long") if uri.length > MAX_URI_LENGTH

      # No allowlist of URIs beyond the server itself. A resource namespace is
      # the server's to define, the connection is already pinned to the one
      # server this view came from, and enumerating readable URIs would mean a
      # `resources/list` on every read.
      Result.new(result: connection.client.resources_read(uri), code: nil, message: nil)
    end

    def failure(code, message)
      Result.new(result: nil, code: code, message: message)
    end
  end
end
