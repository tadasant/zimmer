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

  # Hard cap on stored summary text. The prompt asks for 2-3 sentences; this is
  # the backstop for an agent that answered with an essay, so the panel cannot
  # push the rest of the page off screen.
  MAX_SUMMARY_CHARS = 1200

  # @param fork_session_id [Integer] the summary fork that just came to rest
  # @param failed [Boolean] true when the fork reached `failed` rather than `needs_input`
  def perform(fork_session_id, failed: false)
    # A fork destroyed before harvest leaves nothing to lift and nothing to
    # clean up. `find_by` rather than `find` because the rescue below would
    # swallow RecordNotFound anyway and log it as a failure it is not.
    fork = Session.find_by(id: fork_session_id)
    return if fork.nil?

    source_id = fork.metadata&.dig(SessionStatusSummaryGenerator::FORK_MARKER)
    return if source_id.blank?

    summary = SessionStatusSummary.find_by(session_id: source_id)

    # The record must still name THIS fork. A regenerate that was forced while
    # this fork was still running has moved on — either to a newer fork, or to a
    # newer claim that has not finished copying and so names no fork yet. Either
    # way this answer is stale before it is read; drop it and still clean up.
    #
    # Deliberately not `fork_session_id.present? && ...`: a record naming no fork
    # is not an invitation. Every fork that can reach this job was written onto
    # the record before it was dispatched (SessionStatusSummaryGenerator#call),
    # so a record that does not name it has been claimed by someone else — and
    # accepting the answer there would publish a stale blurb stamped with the
    # newer generation's line count, i.e. labelled current.
    if summary.nil? || summary.fork_session_id != fork.id
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

  # Why the hidden summary fork died, in terms the source session's reader can act on.
  #
  # The user never sees the fork, so anything left only in its metadata is invisible.
  # All three keys are folded in because each failure path writes a different subset:
  # a process death records `failure_reason` + `exit_status`, while an exception death
  # records `failure_reason` ("exception") + `exception_message` and no exit status —
  # which on its own renders as the useless bare word "exception".
  def failure_reason(fork)
    metadata = fork.metadata || {}
    detail = [
      metadata["failure_reason"].presence,
      metadata["exit_status"].presence,
      metadata["exception_message"].presence
    ].compact.join(" — ")

    detail.present? ? "The summary fork failed: #{detail}".truncate(SessionStatusSummary::MAX_ERROR_CHARS) : "The summary fork failed."
  end

  def archive_fork(fork)
    return if fork.nil? || fork.archived?

    fork.archive! if fork.may_archive?
  rescue StandardError => e
    Rails.logger.error "[SessionStatusSummaryHarvestJob] Failed to archive summary fork #{fork&.id}: #{e.message}"
  end
end
