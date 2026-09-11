# frozen_string_literal: true

module McpApps
  # What one MCP server's `tools/list` says about its tools, cached.
  #
  # Two questions are asked of it, and they are asked from different places for
  # different reasons:
  #
  #   * **"does this tool have a view?"** — asked while rendering a timeline row,
  #     which must not make a network call. That path reads the cache and nothing
  #     else (`cached`), so an unwarmed index simply renders no panel until the
  #     first panel request warms it.
  #   * **"may the view call this tool?"** — asked by the proxy, which is already
  #     in a request that is talking to the server anyway, and may fetch.
  #
  # Cached per server URL rather than per server name, so rotating a server's
  # endpoint in the catalog does not serve the old server's tools under the new
  # one's name.
  class ToolIndex
    TTL = 10.minutes

    # One tool: the three facts this feature decides on, plus enough of the
    # tool's own declaration to hand back to a view.
    Entry = Data.define(:name, :title, :description, :input_schema, :resource_uri, :app_callable) do
      def view? = resource_uri.present?
      def app_callable? = app_callable

      # The MCP `Tool` the host puts in `hostContext.toolInfo.tool`. It is a
      # real Tool, `inputSchema` included, and not a convenience shape: the
      # reference SDK validates this against the full schema and a view whose
      # host omits `inputSchema` never finishes `connect()`.
      def to_tool
        {
          "name" => name,
          "title" => title,
          "description" => description.to_s,
          "inputSchema" => input_schema.presence || { "type" => "object", "properties" => {} }
        }
      end
    end

    attr_reader :connection

    # @param connection [McpApps::ServerConnection]
    def initialize(connection)
      @connection = connection
    end

    # The index, fetching `tools/list` if it is not cached.
    #
    # @return [Hash{String => Entry}] keyed by the server's own tool name
    def entries
      @entries ||= build(Rails.cache.fetch(cache_key, expires_in: TTL) { connection.client.tools_list })
    end

    # The index if it is already cached, and nil otherwise. Never makes a call.
    #
    # @return [Hash{String => Entry}, nil]
    def cached
      raw = Rails.cache.read(cache_key)
      raw && build(raw)
    end

    # @param tool [String] the server's own tool name
    # @return [Entry, nil]
    def entry(tool)
      entries[tool.to_s]
    end

    private

    # Only the raw `tools/list` payload is cached — plain hashes, no Zimmer class
    # in the marshalled bytes — so a cache written before a deploy that changes
    # Entry still loads after it.
    def cache_key
      url = connection.server&.url.to_s
      [ "mcp_apps", "tool_index", connection.server_name, Digest::SHA256.hexdigest(url)[0, 16] ]
    end

    def build(tools)
      Array(tools).each_with_object({}) do |tool, index|
        next unless tool.is_a?(Hash)

        name = tool["name"].to_s
        next if name.empty?

        schema = tool["inputSchema"]

        index[name] = Entry.new(
          name: name,
          title: tool["title"].presence || tool["annotations"]&.dig("title").presence || name,
          description: tool["description"],
          input_schema: schema.is_a?(Hash) ? schema : nil,
          resource_uri: McpApps.resource_uri_for(tool),
          app_callable: McpApps.app_callable?(tool)
        )
      end
    end
  end
end
