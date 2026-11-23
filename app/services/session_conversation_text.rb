# frozen_string_literal: true

# What was said in a session: user and assistant messages, with tool calls, tool output
# and bookkeeping left out. Rendered through the session's runtime, so it means the same
# for every one of them.
class SessionConversationText
  def initialize(session)
    @session = session
    @source = TranscriptRuntime.source_for(session)
    @normalizer = TranscriptRuntime.normalizer_for(session)
  end

  # The conversation text of one transcript line, or "" when it carries none.
  #
  # A line that is not JSON is nothing said, and is checked here because the runtime's
  # parser would log what it could not parse, which is the transcript itself.
  def line(raw_line, index)
    return "" unless json?(raw_line)

    @source.parse_events(raw_line).flat_map do |event|
      @normalizer.normalize(event, session: @session, transcript_index: index)
    end.filter_map { |event| text_of(event) }.join("\n")
  end

  private

  def json?(raw_line)
    JSON.parse(raw_line)
    true
  rescue JSON::ParserError
    false
  end

  def text_of(event)
    return unless [ OpenTranscript::Types::USER_MESSAGE, OpenTranscript::Types::ASSISTANT_MESSAGE ].include?(event[:type])
    return if OpenTranscript.blank_message?(event)

    TranscriptTextRenderer.content_text(event[:content]).strip.presence
  end
end
