# frozen_string_literal: true

module McpApps
  # Decides, for one rendered session, which transcript rows get an MCP App panel.
  #
  # It exists because the timeline is a loop. A session detail page renders
  # hundreds of rows and every check this asks — is the feature on, is the server
  # opted in, does this tool have a view — would otherwise be a settings query, a
  # catalog lookup and a cache read PER ROW. One of these is built per render and
  # answers all of them from memory after the first.
  #
  # **It never makes a network call.** The tool index is read from cache and only
  # from cache, because a page load must not depend on a third party answering.
  # An index that has not been fetched yet is `nil` — genuinely unknown — and an
  # unknown answer renders the frame anyway: the frame is lazy, its request is
  # what fetches the index, and from then on the answer for every other row is
  # known. A row whose tool the index says has no view renders nothing at all.
  class TimelineTrigger
    Panel = Data.define(:tool_call_id, :transcript_index, :server_name, :tool)

    attr_reader :session

    def initialize(session)
      @session = session
      @indexes = {}
      @connections = {}
    end

    # @return [Boolean] whether any row on this page could get a panel
    def active?
      return false if session.nil?

      policy.enabled? && (policy.servers & session.all_mcp_servers).any?
    end

    # @param item [Hash] a normalized timeline event
    # @return [Panel, nil]
    def panel_for(item)
      return nil unless active?
      return nil unless item[:type] == OpenTranscript::Types::TOOL_CALL

      tool_call_id = item[:tool_call_id]
      transcript_index = item[:transcript_index]
      return nil if tool_call_id.blank? || transcript_index.blank?

      parsed = ToolName.parse(item[:tool_name], servers: session.all_mcp_servers)
      return nil if parsed.nil?
      return nil unless policy.allows?(parsed.server)
      return nil if view_tool?(parsed.server, parsed.tool) == false

      Panel.new(
        tool_call_id: tool_call_id,
        transcript_index: transcript_index,
        server_name: parsed.server,
        tool: parsed.tool
      )
    end

    private

    def policy
      @policy ||= Policy.snapshot
    end

    # @return [Boolean, nil] nil when the server's tool index has never been read
    def view_tool?(server_name, tool)
      index = index_for(server_name)
      return nil if index.nil?

      index[tool.to_s]&.view? || false
    end

    def index_for(server_name)
      return @indexes[server_name] if @indexes.key?(server_name)

      connection = ServerConnection.new(session, server_name)
      @indexes[server_name] = connection.server.nil? ? {} : ToolIndex.new(connection).cached
    end
  end
end
