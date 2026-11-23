# frozen_string_literal: true

# Moves the transcripts of long-archived sessions out of Postgres.
#
# WHY THIS EXISTS
#
# `session_transcript_chunks` was the one table in the schema with no retention at all.
# Its rows went away only through the ON DELETE CASCADE from `sessions`, and nothing
# deletes sessions, so every transcript Zimmer ever recorded stayed in the database for
# good. On production that took the managed cluster from ~32 GB of live data to close
# to its 60 GiB disk in about two months, and the storage had to be raised by hand
# (https://zimmer.tadasant.com/sessions/30528).
#
# WHAT IT DOES
#
# For each session archived more than `retention_days` ago that still holds chunks,
# oldest archive first:
#
#   1. Reassemble the transcript from its chunks and check it against the row's own
#      `transcript_byte_size` and `transcript_digest`. A session whose chunks disagree
#      with its row is skipped and counted, never offloaded.
#   2. Write it to TranscriptOffloadStore, which re-reads the file and checks the
#      digest again before it returns.
#   3. In one transaction, with the session row locked: re-check that the session is
#      still archived, is not being unarchived right now (Session.reap_protected?),
#      and its transcript is still the one just written, then delete the chunks and
#      stamp `transcript_offloaded_at`.
#
# Chunk rows are deleted only in step 3, and only after step 2 has proven the copy.
# Anything that fails before then leaves the chunks exactly as they were, and the
# next tick tries again.
#
# The stamp is written with `update_all`, so `sessions.updated_at` does not move.
# TranscriptArchiveJob decides what to rebuild by that column; bumping it here would
# make it re-archive every offloaded session once for no change in content.
#
# Nothing is lost to a reader. `Session#transcript` reads an offloaded transcript back
# from the store (ChunkedTranscript), the row's counters answer every size and
# freshness question without it, and unarchiving a session moves its transcript back
# into the chunk table before the session resumes.
#
# DISK
#
# Postgres does not give deleted rows' space back to the filesystem; it marks it
# reusable. So this stops the table growing — new transcripts fill the space old
# ones left — rather than shrinking the files already allocated. Giving that space
# back needs `pg_repack` or `VACUUM FULL`, the same one-time reclamation
# LogRetentionJob's header describes for `logs`.
#
# PACING
#
# A singleton on `maintenance`, bounded by SLICE_BUDGET per tick, so a backlog of
# tens of gigabytes drains over many ticks instead of in one long transaction. One
# transcript is resident at a time.
class TranscriptRetentionJob < ApplicationJob
  include DatabaseRetry
  include SingletonSweep

  queue_as :maintenance

  # Days after archiving before a session's transcript leaves Postgres. Long enough
  # that a session someone is likely to come back to is still in the database —
  # trash retention (Session::TRASH_RETENTION_PERIOD) is four days — and short enough
  # that the chunk table holds roughly a month of conversation rather than all of it.
  # Override with TRANSCRIPT_RETENTION_DAYS; a value below 1 is floored at 1.
  DEFAULT_RETENTION_DAYS = 30
  RETENTION_DAYS_ENV = "TRANSCRIPT_RETENTION_DAYS"

  # How long one tick may work, checked between sessions.
  SLICE_BUDGET = 3.minutes

  # Candidate ids fetched per query.
  BATCH_SIZE = 100

  def self.retention_days
    configured = ENV[RETENTION_DAYS_ENV].presence&.to_i
    [ configured || DEFAULT_RETENTION_DAYS, 1 ].max
  end

  # Archived long enough ago and still holding chunks. Served by
  # `index_sessions_on_transcript_offload_candidates`.
  def self.candidates(now: Time.current)
    Session.archived
      .where(transcript_offloaded_at: nil)
      .where("sessions.transcript_byte_size > 0")
      .where(archived_at: ...(now - retention_days.days))
  end

  def perform(budget: SLICE_BUDGET, now: Time.current)
    deadline = monotonic_now + budget.to_f
    result = { offloaded: 0, skipped: 0, failed: 0, bytes: 0 }
    after = [ Time.at(0), 0 ]

    loop do
      batch = with_db_retry do
        self.class.candidates(now: now)
          .where("(sessions.archived_at, sessions.id) > (?, ?)", *after)
          .order(:archived_at, :id)
          .limit(BATCH_SIZE)
          .pluck(:archived_at, :id)
      end
      break if batch.empty?

      batch.each do |archived_at, id|
        return finish(result) if monotonic_now >= deadline

        after = [ archived_at, id ]
        outcome, bytes = offload(id, now: now)
        result[outcome] += 1
        result[:bytes] += bytes.to_i
      end
    end

    finish(result)
  end

  private

  def finish(result)
    # WARN, because production ships only WARN and above to the log store, and this
    # line is how a drain's progress is visible there. A tick with nothing to do
    # logs nothing.
    if result.values_at(:offloaded, :skipped, :failed).any?(&:positive?)
      Rails.logger.warn(
        "[TranscriptRetentionJob] offloaded #{result[:offloaded]} transcript(s), #{result[:bytes]} bytes; " \
        "skipped #{result[:skipped]}, failed #{result[:failed]}"
      )
    end
    result
  end

  # Returns [:offloaded | :skipped | :failed, bytes moved].
  def offload(session_id, now:)
    row = with_db_retry do
      Session.where(id: session_id)
        .pick(:status, :archived_at, :transcript_offloaded_at, :transcript_byte_size, :transcript_digest)
    end
    return [ :skipped, 0 ] unless row

    status, archived_at, offloaded_at, byte_size, digest = row
    return [ :skipped, 0 ] unless eligible?(status, archived_at, offloaded_at, byte_size, now)

    if digest.blank?
      Rails.logger.warn("[TranscriptRetentionJob] session #{session_id}: no transcript_digest; not offloading")
      return [ :skipped, 0 ]
    end

    content = with_db_retry do
      SessionTranscriptChunk.uncached do
        SessionTranscriptChunk.where(session_id: session_id).order(:seq).pluck(:content).join
      end
    end

    unless content.bytesize == byte_size && Digest::SHA256.hexdigest(content) == digest
      Rails.logger.warn(
        "[TranscriptRetentionJob] session #{session_id}: chunks (#{content.bytesize} bytes) do not match the " \
        "row (#{byte_size} bytes, digest #{digest}); not offloading"
      )
      return [ :skipped, 0 ]
    end

    TranscriptOffloadStore.write(session_id, content, digest: digest)

    committed = with_db_retry do
      Session.transaction do
        locked = Session.lock.where(id: session_id)
          .pick(:status, :archived_at, :transcript_offloaded_at, :transcript_byte_size, :transcript_digest)
        current_status, current_archived_at, current_offloaded_at, current_size, current_digest = locked

        if locked && eligible?(current_status, current_archived_at, current_offloaded_at, current_size, now) &&
           current_size == byte_size && current_digest == digest &&
           !Session.reap_protected?(session_id)
          SessionTranscriptChunk.where(session_id: session_id).delete_all
          Session.where(id: session_id).update_all(transcript_offloaded_at: Time.current)
          true
        else
          false
        end
      end
    end

    committed ? [ :offloaded, byte_size ] : [ :skipped, 0 ]
  rescue TranscriptOffloadStore::Error, SystemCallError => e
    Rails.logger.error("[TranscriptRetentionJob] session #{session_id}: #{e.class}: #{e.message}")
    [ :failed, 0 ]
  end

  def eligible?(status, archived_at, offloaded_at, byte_size, now)
    status.to_s == "archived" && offloaded_at.nil? && byte_size.to_i.positive? &&
      archived_at.present? && archived_at < now - self.class.retention_days.days
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
