# frozen_string_literal: true

# The last thing a session said: the text of its newest assistant message, read
# from the end of its transcript, in any runtime. nil when it has said nothing
# in the last LINES events.
module SessionLastWords
  LINES = 200

  def self.for(session)
    total = session.transcript_line_count.to_i
    return nil if total.zero?

    source = TranscriptRuntime.source_for(session)
    normalizer = TranscriptRuntime.normalizer_for(session)
    session.each_transcript_line([ total - LINES, 0 ].max, total, reverse: true) do |index, line|
      source.parse_events(line).reverse_each do |raw|
        normalizer.normalize(raw, session: session, transcript_index: index).reverse_each do |event|
          next unless event[:type] == OpenTranscript::Types::ASSISTANT_MESSAGE
          next if OpenTranscript.blank_message?(event)

          text = TranscriptTextRenderer.content_text(event[:content]).strip
          return text if text.present?
        end
      end
    end
    nil
  end
end
