# frozen_string_literal: true

# --- Claude Code transcript shape --------------------------------------------
class TranscriptHooks::ClaudeToolCallParser < TranscriptHooks::ToolCallParser
  def shell_calls
    @shell_calls ||= content_blocks.filter_map do |block|
      next unless block["type"] == "tool_use"
      next unless block["name"] == "Bash"

      command = block.dig("input", "command")
      next unless command.is_a?(String)
      next unless block["id"]

      { id: block["id"], command: command }
    end
  end

  def tool_results
    @tool_results ||= content_blocks.filter_map do |block|
      next unless block["type"] == "tool_result"

      result_content = block["content"]
      next unless result_content.is_a?(String)

      { id: block["tool_use_id"], text: result_content, is_error: !!block["is_error"] }
    end
  end

  private

  # Every content block across every message, in transcript order.
  def content_blocks
    @content_blocks ||= parsed_transcript.flat_map do |message|
      message_data = message["message"] || message
      content = message_data["content"]
      content.is_a?(Array) ? content : []
    end
  end
end
