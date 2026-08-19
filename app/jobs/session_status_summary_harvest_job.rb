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
#
# **A pause is not proof that the fork answered.** AuthOutageParkService parks a
# session that has run out of login pool by scheduling a wake and letting it
# reach `pause!` — the same transition a finished turn reaches. A parked summary
# fork never ran its turn, so the last assistant text in its transcript is the
# runtime's own refusal ("You've hit your session limit · resets 10pm (UTC)",
# "Not logged in · Please run /login"). Harvesting that as an answer published
# it as the source session's Status blurb, stamped `ready` at the requested line
# count — i.e. labelled CURRENT, so `stale?` was false and nothing would ever
# replace it. 73 sessions in this deployment were showing a quota refusal as
# their status when this was found; 91 of the 92 summary forks in one id window
# carried the park marker. The park marker and #refused_answer? are what keep
# a refusal out.
class SessionStatusSummaryHarvestJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  # Hard cap on stored summary text. The prompt asks for 2-3 sentences; this is
  # the backstop for an agent that answered with an essay, so the panel cannot
  # push the rest of the page off screen.
  MAX_SUMMARY_CHARS = 1200

  # The refusals a runtime writes into its own transcript instead of doing the
  # work, borrowed from the services that already own each wording so there is
  # one definition of each per codebase. ApiErrorRetryService's covers the usage
  # limits ("You've hit your session limit · resets 10pm (UTC)");
  # AuthRecoveryService's covers the logged-out signature.
  REFUSAL_PATTERNS = [
    ApiErrorRetryService::ACCOUNT_QUOTA_LIMIT_PATTERN,
    AuthRecoveryService::AUTH_RECOVERABLE_ERROR_PATTERN
  ].freeze

  # A refusal is a single short line. A real answer is 2-3 sentences carrying
  # markdown links, and is an order of magnitude longer — so requiring the whole
  # answer to be one line under this length keeps the patterns off a genuine
  # summary that happens to be ABOUT a session which hit a limit. Getting that
  # judgement wrong costs a regeneration, never a wrong blurb.
  MAX_REFUSAL_CHARS = 200

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

    # A parked fork is not a finished one. Reading the park marker rather than
    # sniffing the transcript is the same test AgentSessionJob applies to decide
    # whether an exit was a completed turn, so both paths agree on what a park is.
    parked = park_reason(fork)
    text = (failed || parked) ? nil : extracted_summary(fork)

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
        # NOT a summary write: `summary`, `generated_at` and
        # `transcript_line_count` are all left alone, so whatever was displayed
        # stays displayed and stays STALE — which is what makes the session a
        # candidate for StatusSummaryBackstopJob to retry once the pool recovers.
        summary.update!(state: "failed", error: no_answer_reason(fork, failed: failed, parked: parked))
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
  #
  # A refusal never becomes an answer. The park marker catches nearly every one
  # of these, but the runtime can also print its limit line and exit cleanly
  # before rotation has anything left to rotate into — in which case there is no
  # park to read and the text is the only evidence.
  def normalize_text(text)
    return nil if text.blank?

    cleaned = text.strip
    cleaned = cleaned.sub(/\A```[a-z]*\n/i, "").sub(/\n?```\z/, "").strip
    return nil if refused_answer?(cleaned)

    cleaned.truncate(MAX_SUMMARY_CHARS)
  end

  # Whether the fork wrote the runtime's refusal where its answer should be.
  def refused_answer?(text)
    return false if text.length > MAX_REFUSAL_CHARS || text.include?("\n")

    REFUSAL_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  # The park this fork is sitting in, or nil if it is not parked.
  def park_reason(fork) = fork.metadata&.dig("auth_outage_reason").presence

  # Why no answer was stored, in terms the source session's reader can act on.
  # A park is named as one, because "out of quota, parked until it resets" tells
  # the reader the summary will come back on its own and the bare fork failure
  # does not.
  def no_answer_reason(fork, failed:, parked:)
    return failure_reason(fork) if failed
    return "The summary fork was parked before it could answer (#{parked}). It will be retried." if parked

    "The summary fork produced no answer."
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

    fork.archive_actor = "Zimmer's status-summary fork cleanup"
    fork.archive! if fork.may_archive?
  rescue StandardError => e
    Rails.logger.error "[SessionStatusSummaryHarvestJob] Failed to archive summary fork #{fork&.id}: #{e.message}"
  end
end
