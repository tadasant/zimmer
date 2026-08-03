# frozen_string_literal: true

# Renders a parsed transcript as plain text.
#
# One renderer, two surfaces: `GET /api/v1/sessions/:id/transcript` and the MCP
# `get_session` tool's `transcript_format: "text"`. They used to carry separate
# copies of this `case`, which is how they drifted into rendering the same
# session differently — hence the single class.
#
# Two rules the copies both got wrong:
#
#   * **Every entry is rendered.** An entry whose type has no special layout is
#     labeled and dumped, not dropped. `system`, `result`, `summary` and whatever
#     a future harness emits are real parts of the conversation, and omitting
#     them made the text transcript quietly disagree with the raw one.
#   * **Content is often an array of blocks**, not a String. Pushing that array
#     into the line list left `join` to call `to_s` on each block, emitting Ruby
#     hash inspect output into what is supposed to be readable text.
class TranscriptTextRenderer
  # How much of a tool result to keep. Results are frequently whole file dumps;
  # this rendering is for reading, not for reconstructing them.
  TOOL_RESULT_TRUNCATION = 500

  # How much of an unrecognized entry to keep. Rendering these instead of dropping
  # them is the point of this class, but they must not be rendered *whole*: a Codex
  # rollout is entirely `session_meta` / `response_item` / `event_msg` /
  # `turn_context` envelopes, so every one of its entries lands here, and Claude
  # Code's `file-history-snapshot` entries embed entire files. Pretty-printing
  # those in full would make this "readable summary" larger than the raw
  # transcript, and it feeds `get_session`'s text format straight into an agent's
  # context window.
  UNKNOWN_ENTRY_TRUNCATION = 1_000

  class << self
    # @param entries [Array] the output of Session#parsed_transcript
    # @return [String] the plain-text rendering
    def render(entries)
      Array(entries).flat_map { |entry| entry_lines(entry) }.join("\n")
    end

    def entry_lines(entry)
      return [ "--- Unknown ---", entry.to_s, "" ] unless entry.is_a?(Hash)
      return open_transcript_entry_lines(entry) if OpenTranscript::Types::ALL.include?(entry[:type])

      type = entry["type"].to_s
      message = entry["message"].is_a?(Hash) ? entry["message"] : entry
      content = message["content"]

      case type
      when "user"
        [ "--- User ---", content_text(content), "" ]
      when "assistant"
        [ "--- Assistant ---", content_text(content), "" ]
      when "tool_use"
        [ "--- Tool Use: #{message['name'] || 'unknown'} ---", content_text(message["input"] || content), "" ]
      when "tool_result"
        [ "--- Tool Result ---", content_text(content).truncate(TOOL_RESULT_TRUNCATION), "" ]
      else
        label = type.presence || "Entry"
        role = message["role"].presence
        body = content_text(content.nil? ? entry : content).truncate(UNKNOWN_ENTRY_TRUNCATION)
        [ "--- #{label.titleize}#{role ? " (#{role})" : ''} ---", body, "" ]
      end
    end

    def open_transcript_entry_lines(entry)
      case entry[:type]
      when OpenTranscript::Types::USER_MESSAGE
        [ "--- User ---", content_text(entry[:content]), "" ]
      when OpenTranscript::Types::ASSISTANT_MESSAGE
        [ "--- Assistant ---", content_text(entry[:content]), "" ]
      when OpenTranscript::Types::THINKING
        [ "--- Thinking ---", entry[:text].to_s, "" ]
      when OpenTranscript::Types::TOOL_CALL
        [ "--- Tool Use: #{entry[:tool_name] || 'unknown'} ---", content_text(entry[:arguments]), "" ]
      when OpenTranscript::Types::TOOL_RESULT
        [ "--- Tool Result ---", content_text(entry[:output]).truncate(TOOL_RESULT_TRUNCATION), "" ]
      when OpenTranscript::Types::COMPACTION
        [ "--- Compaction ---", entry[:summary].to_s, "" ]
      else
        label = entry[:type].to_s.titleize
        [ "--- #{label} ---", content_text(entry.except(:provider_raw)).truncate(UNKNOWN_ENTRY_TRUNCATION), "" ]
      end
    end

    # Render an entry's `content`, which is a String on some entries and an array
    # of content blocks on many others.
    def content_text(content)
      case content
      when nil then ""
      when String then content
      when Array then content.map { |block| block_text(block) }.reject(&:blank?).join("\n")
      when Hash then block_text(content)
      else content.to_s
      end
    end

    def block_text(block)
      return block.to_s unless block.is_a?(Hash)

      case block["type"]
      when "text" then block["text"].to_s
      when "thinking" then "[thinking] #{block['thinking']}"
      when "image" then "[image]"
      when "tool_use" then "[tool_use: #{block['name'] || 'unknown'}] #{JSON.generate(block['input'])}"
      when "tool_result" then "[tool_result] #{content_text(block['content']).truncate(TOOL_RESULT_TRUNCATION)}"
      else JSON.pretty_generate(block)
      end
    rescue JSON::GeneratorError, Encoding::UndefinedConversionError
      block.to_s
    end
  end
end
