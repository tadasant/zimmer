# frozen_string_literal: true

# Lifts a finished status-summary fork's answer onto the source session and
# disposes of the fork.
#
# Enqueued from SessionStateMachine's pause/fail hooks — a summary fork reaching
# either state is the completion signal, since the fork exists only to run one
# turn. Everything the fork produced lives in its transcript; this job reads the
# assistant text it wrote AFTER the fork point (its own turn, not the copied
# conversation), stores it, and archives the fork so the copied clone is
# reclaimed on the normal trash path.
#
# The fork is archived even when nothing usable came back. A fork left behind
# holds a full copy of a repository.
class SessionStatusSummaryHarvestJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # Hard cap on stored summary text. The prompt asks for 2-3 sentences; this is
  # the backstop for an agent that answered with an essay, so the panel cannot
  # push the rest of the page off screen.
  MAX_SUMMARY_CHARS = 1200

  # @param fork_session_id [Integer] the summary fork that just came to rest
  # @param failed [Boolean] true when the fork reached `failed` rather than `needs_input`
  def perform(fork_session_id, failed: false)
    fork = Session.find(fork_session_id)
    source_id = fork.metadata&.dig(SessionStatusSummaryGenerator::FORK_MARKER)
    return if source_id.blank?

    summary = SessionStatusSummary.find_by(session_id: source_id)

    # A regenerate that was forced while this fork was still running has already
    # pointed the record at a newer fork. This one's answer is stale before it
    # is read; drop it and still clean up.
    if summary.nil? || (summary.fork_session_id.present? && summary.fork_session_id != fork.id)
      archive_fork(fork)
      return
    end

    text = failed ? nil : extracted_summary(fork)

    with_db_retry do
      if text.present?
        summary.update!(
          summary: text,
          generated_at: Time.current,
          transcript_line_count: summary.requested_line_count.to_i,
          state: "ready",
          error: nil
        )
      else
        summary.update!(
          state: "failed",
          error: failed ? failure_reason(fork) : "The summary fork produced no answer."
        )
      end
    end

    archive_fork(fork)
  rescue StandardError => e
    Rails.logger.error "[SessionStatusSummaryHarvestJob] Failed to harvest fork #{fork_session_id}: #{e.message}"
    archive_fork(Session.find_by(id: fork_session_id))
  end

  private

  # The text of the last assistant message the fork wrote in its own turn.
  # Messages at or before the fork point are the copied conversation, not the
  # answer, so the scan starts one past it.
  def extracted_summary(fork)
    start_index = fork.metadata&.dig("forked_at_message_index").to_i + 1
    total = fork.transcript_line_count
    return nil if total <= start_index

    normalizer = TranscriptRuntime.normalizer_for(fork)

    texts = fork.parsed_transcript_range(start_index, total).flat_map do |raw_event|
      normalizer.normalize(raw_event, session: fork, transcript_index: raw_event["_transcript_index"])
    end.compact.filter_map do |event|
      next unless event[:type] == OpenTranscript::Types::ASSISTANT_MESSAGE
      next if OpenTranscript.blank_message?(event)

      text_content_from_parts(event[:content]).presence
    end

    normalize_text(texts.last)
  end

  def text_content_from_parts(parts)
    return "" unless parts.is_a?(Array)

    parts.filter_map do |part|
      next unless part.is_a?(Hash) && part["type"] == "text"

      part["text"].presence
    end.join("\n\n")
  end

  # Strips the wrapper an agent sometimes puts around a "reply with only X"
  # answer (a fenced block), then truncates.
  def normalize_text(text)
    return nil if text.blank?

    cleaned = text.strip
    cleaned = cleaned.sub(/\A```[a-z]*\n/i, "").sub(/\n?```\z/, "").strip
    cleaned.truncate(MAX_SUMMARY_CHARS)
  end

  def failure_reason(fork)
    reason = fork.metadata&.dig("failure_reason").presence
    reason ? "The summary fork failed: #{reason}" : "The summary fork failed."
  end

  def archive_fork(fork)
    return if fork.nil? || fork.archived?

    fork.archive! if fork.may_archive?
  rescue StandardError => e
    Rails.logger.error "[SessionStatusSummaryHarvestJob] Failed to archive summary fork #{fork&.id}: #{e.message}"
  end
end
