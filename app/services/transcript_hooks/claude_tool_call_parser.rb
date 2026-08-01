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

      text = result_text(block["content"])
      next if text.blank?

      { id: block["tool_use_id"], text: text, is_error: !!block["is_error"] }
    end
  end

  def assistant_texts
    @assistant_texts ||= parsed_transcript.filter_map do |message|
      message_data = message["message"] || message
      next unless message["type"] == "assistant" || message_data["role"] == "assistant"

      text = assistant_text(message_data["content"])
      text if text.present?
    end
  end

  private

  # Assistant content is either a bare String or an array of content blocks, of
  # which only `text` blocks are prose (tool_use blocks are handled separately).
  def assistant_text(content)
    case content
    when String
      content
    when Array
      content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join("\n")
    else
      ""
    end
  end

  # Claude Code serializes a tool result either as a bare String or as an array of
  # content items ({ "type" => "text", "text" => ... }). Both shapes appear in real
  # transcripts, and a hook that reads only the first is blind to half of them.
  def result_text(content)
    case content
    when String
      content
    when Array
      content.filter_map { |item| item["text"] if item.is_a?(Hash) && item["text"].is_a?(String) }.join("\n")
    else
      ""
    end
  end

  # Every content block across every message, in transcript order.
  def content_blocks
    @content_blocks ||= parsed_transcript.flat_map do |message|
      message_data = message["message"] || message
      content = message_data["content"]
      content.is_a?(Array) ? content : []
    end
  end
end
