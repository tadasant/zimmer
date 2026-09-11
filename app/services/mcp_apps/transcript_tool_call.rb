# frozen_string_literal: true

module McpApps
  # The transcript-driven trigger: the agent's own MCP tool call, located in the
  # normalized transcript, together with the result it already produced.
  #
  # This is what makes the feature a feature rather than the spike. Nothing here
  # calls a tool. The agent called it, the runtime wrote both the call and its
  # result into the transcript, and this class reads them back out — so the
  # fragment renders against exactly the result the agent saw, and clicking
  # around the session detail page can never re-run somebody's tool.
  #
  # The lookup is bounded. `transcript_index` says where in the transcript the
  # call was, and only a window of entries from there is parsed; a result follows
  # its call within a handful of lines in every runtime Zimmer supports. The index
  # is a hint from the URL and is never trusted: the call found there has to carry
  # the `tool_call_id` that was asked for, or this resolves to nothing.
  class TranscriptToolCall
    # How many transcript entries after the call to read looking for its result.
    # A turn's worth of lines, not a transcript's.
    WINDOW = 40

    attr_reader :session, :tool_call_id, :transcript_index

    # @param session [Session]
    # @param tool_call_id [String] the runtime's id for the call
    # @param transcript_index [Integer] where in the transcript the call is
    def initialize(session:, tool_call_id:, transcript_index:)
      @session = session
      @tool_call_id = tool_call_id.to_s
      @transcript_index = transcript_index.to_i
    end

    # @return [Boolean] whether the named call was found where it was claimed to be
    def found? = call_event.present?

    # @return [String, nil] catalog name of the MCP server the tool belongs to
    def server_name = parsed_name&.server

    # @return [String, nil] the server's own name for the tool
    def tool = parsed_name&.tool

    # @return [Hash] the arguments the agent called the tool with
    def arguments
      call_event&.dig(:arguments) || {}
    end

    # The agent's tool result, shaped as the `CallToolResult` the MCP Apps
    # protocol delivers to a view.
    #
    # The transcript stores the result normalized into OpenTranscripts content
    # parts, which is the same `{type, text}` shape MCP uses, so the content
    # blocks are carried straight across. `structuredContent` is reconstructed
    # when the text parses as a JSON object: most servers return their structured
    # payload as JSON text in the first block (FastMCP does), and a view that
    # reads `structuredContent` would otherwise see nothing. It is derived, so it
    # is only ever added when the parse succeeds.
    #
    # @return [Hash, nil] nil when the call has no result in the transcript yet
    def result
      return nil if result_event.nil?

      content = Array(result_event[:output]).filter_map do |part|
        next unless part.is_a?(Hash)
        next unless part["type"] == "text"

        { "type" => "text", "text" => part["text"].to_s }
      end

      payload = { "content" => content, "isError" => !!result_event[:is_error] }
      structured = structured_from(content)
      payload["structuredContent"] = structured if structured
      payload
    end

    private

    def parsed_name
      return @parsed_name if defined?(@parsed_name)

      @parsed_name = ToolName.parse(call_event&.dig(:tool_name), servers: session.all_mcp_servers)
    end

    def call_event = located[:call]
    def result_event = located[:result]

    def located
      @located ||= locate
    end

    # One pass over the window, finding both the call and its result.
    def locate
      call = nil
      result = nil

      normalized_window.each do |event|
        next unless event[:tool_call_id] == tool_call_id

        case event[:type]
        when OpenTranscript::Types::TOOL_CALL
          call ||= event
        when OpenTranscript::Types::TOOL_RESULT
          result ||= event
        end
      end

      # The call has to be at the index the caller named. A window that contains
      # the id somewhere else is a different call with a recycled id, or a URL
      # pointing at the wrong row; either way this is not it.
      return { call: nil, result: nil } unless call && call[:transcript_index] == transcript_index

      { call: call, result: result }
    end

    def normalized_window
      return [] if transcript_index.negative?

      normalizer = TranscriptRuntime.normalizer_for(session)
      entries = session.parsed_transcript_range(transcript_index, transcript_index + WINDOW)

      entries.flat_map do |entry|
        index = entry["_transcript_index"] || transcript_index
        normalizer.normalize(entry, session: session, transcript_index: index)
      end
    rescue StandardError => e
      Rails.logger.warn("[mcp-apps] could not read transcript for session #{session.id}: #{e.class}: #{e.message}")
      []
    end

    def structured_from(content)
      text = content.first&.fetch("text", nil)
      return nil if text.blank?

      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end
end
