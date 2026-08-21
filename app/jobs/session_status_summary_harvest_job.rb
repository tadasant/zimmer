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
        # stays displayed and stays STALE — which is what keeps the session a
        # candidate for a retry.
        summary.update!(state: "failed", error: no_answer_reason(fork, failed: failed, parked: parked))
      end
    end

    archive_fork(fork)

    # The fork produced nothing, so try the path that does not need one — but
    # ONLY when a fork genuinely could not have delivered. A park means the pool
    # is empty, which is exactly when waiting for the next sweep to re-fork
    # produces one more parked fork instead of a blurb. A fork that died of
    # something else while the pool was healthy is a different case: re-forking
    # is the right repair, the sweep will do it, and downgrading here would
    # stamp a terser blurb as CURRENT and stop the sweep ever trying again.
    #
    # Enqueued rather than run inline so this job stays short, and only after
    # the record is committed as `failed`, so the retry claims a record no other
    # runner holds.
    enqueue_headless_retry(source_id) if text.blank? && (parked || pool_exhausted?(fork.agent_runtime))
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

    StatusSummaryAnswer.clean(texts.last)
  end

  def text_content_from_parts(parts)
    return "" unless parts.is_a?(Array)

    parts.filter_map do |part|
      next unless part.is_a?(Hash) && part["type"] == "text"

      part["text"].presence
    end.join("\n\n")
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

  # Whether this runtime's login pool has nothing left to run another fork on.
  # Fail-CLOSED here, unlike the generator: an unreadable pool is not a reason to
  # downgrade a session whose fork may simply have crashed, and the sweep is
  # still behind this as the repair of last resort.
  def pool_exhausted?(runtime)
    RuntimeAuthProvider.for(runtime).accounts.available.none?
  rescue StandardError => e
    Rails.logger.warn "[SessionStatusSummaryHarvestJob] Could not read the #{runtime} account pool: #{e.message}"
    false
  end

  # Asks for a pool-independent retry of a generation the fork could not deliver.
  # Unforced, so it costs nothing when the record turns out to be current after
  # all (a concurrent forced Regenerate that landed while this fork was dying).
  def enqueue_headless_retry(source_id)
    SessionStatusSummaryJob.perform_later(source_id, headless: true)
  rescue StandardError => e
    Rails.logger.error "[SessionStatusSummaryHarvestJob] Could not enqueue a headless retry for session #{source_id}: #{e.message}"
  end

  def archive_fork(fork)
    return if fork.nil? || fork.archived?

    fork.archive_actor = "Zimmer's status-summary fork cleanup"
    fork.archive! if fork.may_archive?
  rescue StandardError => e
    Rails.logger.error "[SessionStatusSummaryHarvestJob] Failed to archive summary fork #{fork&.id}: #{e.message}"
  end
end
