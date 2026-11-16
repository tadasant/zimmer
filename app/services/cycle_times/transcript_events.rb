# frozen_string_literal: true

module CycleTimes
  # The timestamped events of one session's stored transcript, reduced to what
  # the lane builder needs.
  #
  # Reads through the runtime's TranscriptNormalizer, so Claude Code, Codex and
  # Pi transcripts all arrive as the same OpenTranscripts event types, and
  # streams the stored transcript line by line (Session#each_transcript_line),
  # so a 30 MB transcript is never held as one string. A line that does not
  # parse is skipped: one bad line costs that event's precision, not the row.
  module TranscriptEvents
    Event = Data.define(:at, :type, :tool_call_id, :tool_name, :arguments)

    KEPT = [
      OpenTranscript::Types::USER_MESSAGE,
      OpenTranscript::Types::ASSISTANT_MESSAGE,
      OpenTranscript::Types::THINKING,
      OpenTranscript::Types::TOOL_CALL,
      OpenTranscript::Types::TOOL_RESULT,
      OpenTranscript::Types::SUBAGENT_SPAWN,
      OpenTranscript::Types::COMPACTION,
      OpenTranscript::Types::ERROR,
      OpenTranscript::Types::SYSTEM_EVENT
    ].freeze

    module_function

    # @param session [Session]
    # @return [Array<Event>] sorted by time
    def for(session)
      normalizer = TranscriptRuntime.normalizer_for(session)
      count = session.transcript_line_count.to_i
      return [] if count.zero?

      events = []
      session.each_transcript_line(0, count) do |index, line|
        next if line.blank?

        raw = JSON.parse(line)
        next unless raw.is_a?(Hash) && raw["timestamp"].present?

        normalizer.normalize(raw, session: session, transcript_index: index).each do |event|
          next unless KEPT.include?(event[:type]) && event[:sort_time]

          events << Event.new(
            at: event[:sort_time],
            type: event[:type],
            tool_call_id: event[:tool_call_id],
            tool_name: event[:tool_name],
            arguments: event[:arguments]
          )
        end
      rescue StandardError => e
        Rails.logger.debug { "[CycleTimes] skipped transcript line #{index} of session #{session.id}: #{e.class}" }
      end

      events.sort_by.with_index { |event, i| [ event.at, i ] }
    end
  end
end
