# frozen_string_literal: true

# Copies the transcripts of sessions archived more than COPY_AFTER ago to object storage,
# oldest archive first. It deletes nothing: the copy is made well before anything could
# need it, and TranscriptCopy records where it is.
#
# Off until TranscriptStorage is configured. See docs/operate/background-jobs.md.
#
# A transcript is copied again only when it has changed: the row's digest is not the
# copy's, or its subagents are not the ones that were copied. A session whose chunks
# disagree with its own row is set aside at that digest, and one that fails for a reason of
# its own waits RETRY_AFTER, so neither holds up the sessions behind it. /health counts both.
class TranscriptCopyJob < ApplicationJob
  include DatabaseRetry
  include SingletonSweep

  queue_as :maintenance

  DEFAULT_COPY_AFTER_DAYS = 7
  COPY_AFTER_DAYS_ENV = "TRANSCRIPT_COPY_AFTER_DAYS"

  # How long one tick may work, checked between sessions.
  SLICE_BUDGET = 3.minutes
  BATCH_SIZE = 100

  # A tick ends after this many failures of the store in a row.
  MAX_STORE_FAILURES = 3

  # And after this many sessions in a row have failed for what looks like their own reason,
  # because then it is not: a full disk, say. Each of them still waits RETRY_AFTER, so a
  # run of bad sessions at the head of the queue clears itself over a few ticks.
  MAX_SESSION_FAILURES = 10

  # How long a session that failed for its own reasons waits before it is tried again.
  RETRY_AFTER = 1.day

  SKIPPED_DIGEST_KEY = "transcript_copy_skipped_digest"
  RETRY_AT_KEY = "transcript_copy_retry_at"

  class << self
    def copy_after_days
      [ Integer(ENV[COPY_AFTER_DAYS_ENV].to_s, exception: false) || DEFAULT_COPY_AFTER_DAYS, 1 ].max
    end

    # Archived long enough ago, with a transcript, and no copy in +bucket+ of what it and
    # its subagents hold now.
    def candidates(bucket:, now: Time.current)
      eligible(now: now)
        .where("(sessions.metadata ->> ?) IS DISTINCT FROM sessions.transcript_digest", SKIPPED_DIGEST_KEY)
        .where("COALESCE(sessions.metadata ->> ?, '') <= ?", RETRY_AT_KEY, now.utc.iso8601)
        .where(<<~SQL.squish, bucket)
          NOT EXISTS (
            SELECT 1 FROM transcript_copies tc
            WHERE tc.session_id = sessions.id AND tc.transcript_digest = sessions.transcript_digest AND tc.bucket = ?
              AND tc.subagents_fingerprint = (
                SELECT #{TranscriptCopier::SUBAGENTS_FINGERPRINT_SQL} FROM subagent_transcripts st WHERE st.session_id = tc.session_id
              )
          )
        SQL
    end

    # Set aside because their chunks disagree with their row.
    def skipped(now: Time.current)
      eligible(now: now).where("(sessions.metadata ->> ?) = sessions.transcript_digest", SKIPPED_DIGEST_KEY)
    end

    # Waiting after a failure of their own.
    def failing(now: Time.current)
      eligible(now: now).where("(sessions.metadata ->> ?) > ?", RETRY_AT_KEY, now.utc.iso8601)
    end

    private

    def eligible(now:)
      Session.archived.where(archived_at: ...(now - copy_after_days.days))
        .where("sessions.transcript_byte_size > 0").where.not(transcript_digest: nil)
    end
  end

  def perform(budget: SLICE_BUDGET, now: Time.current)
    result = { copied: 0, skipped: 0, failed: 0, store_failed: 0, bytes: 0 }
    storage = TranscriptStorage.record_configuration
    unless storage.configured?
      Rails.logger.warn("[TranscriptCopyJob] not copying: #{storage.problem}") if storage.problem
      return result
    end

    deadline = monotonic_now + budget.to_f
    copier = TranscriptCopier.new(storage.client)
    store_failures = session_failures = 0
    each_candidate(storage.bucket, now) do |session_id|
      break if monotonic_now >= deadline

      outcome, bytes = copy(copier, session_id)
      result[outcome] += 1
      result[:bytes] += bytes
      store_failures = outcome == :store_failed ? store_failures + 1 : 0
      session_failures = outcome == :failed ? session_failures + 1 : 0
      break if store_failures >= MAX_STORE_FAILURES || session_failures >= MAX_SESSION_FAILURES
    end
    finish(result)
  end

  private

  def each_candidate(bucket, now)
    after = [ Time.at(0), 0 ]
    loop do
      batch = with_db_retry do
        self.class.candidates(bucket: bucket, now: now).where("(sessions.archived_at, sessions.id) > (?, ?)", *after)
          .order(:archived_at, :id).limit(BATCH_SIZE).pluck(:archived_at, :id)
      end
      return if batch.empty?

      batch.each do |archived_at, id|
        after = [ archived_at, id ]
        yield id
      end
    end
  end

  # @return [Array(Symbol, Integer)] what happened, and the transcript bytes copied
  def copy(copier, session_id)
    record = copier.copy(session_id)
    record ? [ :copied, record.transcript_byte_size ] : [ :skipped, 0 ]
  rescue TranscriptCopier::Moved
    [ :skipped, 0 ]
  rescue TranscriptCopier::Mismatch => e
    Rails.logger.warn("[TranscriptCopyJob] session #{session_id}: #{e.message}; set aside until it changes")
    mark(Session.where(id: session_id, transcript_digest: e.digest), SKIPPED_DIGEST_KEY, e.digest)
    [ :skipped, 0 ]
  rescue TranscriptStorage::RequestFailed => e
    Rails.logger.error("[TranscriptCopyJob] session #{session_id}: #{e.message}")
    [ :store_failed, 0 ]
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed
    raise
  rescue StandardError => e
    # Its message only where it is ours: another's could quote the transcript.
    Rails.logger.error("[TranscriptCopyJob] session #{session_id}: #{e.is_a?(TranscriptStorage::Error) ? e.message : e.class}; " \
      "retrying in #{RETRY_AFTER.inspect}")
    mark(Session.where(id: session_id), RETRY_AT_KEY, RETRY_AFTER.from_now.utc.iso8601)
    [ :failed, 0 ]
  end

  # `update_all`, so `updated_at` does not move: TranscriptArchiveJob reads it as a change.
  def mark(scope, key, value)
    with_db_retry do
      scope.update_all([ "metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)", key, value ])
    end
  end

  # WARN, because production ships only WARN and above. A tick with nothing to do is silent.
  def finish(result)
    if result.except(:bytes).values.any?(&:positive?)
      Rails.logger.warn("[TranscriptCopyJob] copied #{result[:copied]} transcript(s), #{result[:bytes]} bytes; " \
        "skipped #{result[:skipped]}, failed #{result[:failed]}, store failures #{result[:store_failed]}")
    end
    result
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
